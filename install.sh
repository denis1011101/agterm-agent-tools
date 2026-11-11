#!/usr/bin/env bash
# install.sh — Installer and manager for agterm-agent-tools
# Supports:
#   ./install.sh             Install tools, symlinks, hooks, and skills
#   ./install.sh --dry-run   Show actions without modifying system
#   ./install.sh --uninstall Remove symlinks and installed hooks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
UNINSTALL=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install or uninstall agterm-agent-tools (mailbox-chat, status hooks, skills).

Options:
  --dry-run       Show actions that would be taken without modifying anything
  --uninstall     Remove installed symlinks, skills, and configuration hooks
  -h, --help      Display this help message

Components installed:
  - CLI tools:
      ~/.local/bin/mailbox-chat.py -> bin/mailbox-chat.py
      ~/.local/bin/codex-mailbox   -> bin/codex-mailbox
  - agterm hooks:
      ~/.config/agterm/hooks/agy/agy-status-hook.sh        -> hooks/agy/agy-status-hook.sh
      ~/.config/agterm/agent-status/agterm-agent-status.sh -> hooks/agterm/agterm-agent-status.sh
      ~/.config/agterm/agent-status/agterm-codex-status.sh -> hooks/agterm/agterm-codex-status.sh
      ~/.config/agterm/hooks.conf (mailbox hook entry)
  - Skills:
      ~/.gemini/config/skills/mailbox-chat -> skills/agy/mailbox-chat
      ~/.codex/skills/mailbox-chat         -> skills/codex/mailbox-chat
  - Configuration:
      ~/.gemini/config/hooks.json (merged agy lifecycle hooks)
      ~/.codex/config.toml (Codex lifecycle & mailbox hooks, if ~/.codex exists)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

log_info() {
    printf "==> %s\n" "$*"
}

log_dry() {
    printf "  [dry-run] %s\n" "$*"
}

log_action() {
    if (( DRY_RUN )); then
        log_dry "$*"
    else
        printf "  %s\n" "$*"
    fi
}

make_symlink() {
    local src="$1"
    local dest="$2"

    if (( UNINSTALL )); then
        if [[ -L "$dest" ]]; then
            local target
            target="$(readlink -f "$dest" 2>/dev/null || true)"
            local expected
            expected="$(readlink -f "$src" 2>/dev/null || true)"
            if [[ "$target" == "$expected" ]]; then
                log_action "Removing symlink: $dest"
                if (( ! DRY_RUN )); then
                    rm -f "$dest"
                fi
            fi
        fi
        return 0
    fi

    # Install mode
    local dest_dir
    dest_dir="$(dirname "$dest")"
    if [[ ! -d "$dest_dir" ]]; then
        log_action "Creating directory: $dest_dir"
        if (( ! DRY_RUN )); then
            mkdir -p "$dest_dir"
        fi
    fi

    if [[ -L "$dest" ]]; then
        local current_target
        current_target="$(readlink -f "$dest" 2>/dev/null || true)"
        local desired_target
        desired_target="$(readlink -f "$src" 2>/dev/null || true)"
        if [[ "$current_target" == "$desired_target" ]]; then
            log_action "Symlink already up to date: $dest"
            return 0
        else
            log_action "Updating symlink: $dest -> $src"
            if (( ! DRY_RUN )); then
                rm -f "$dest"
                ln -s "$src" "$dest"
            fi
            return 0
        fi
    elif [[ -e "$dest" ]]; then
        local backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
        log_action "Backing up existing non-symlink: $dest -> $backup"
        if (( ! DRY_RUN )); then
            mv "$dest" "$backup"
            ln -s "$src" "$dest"
        fi
    else
        log_action "Linking: $dest -> $src"
        if (( ! DRY_RUN )); then
            ln -s "$src" "$dest"
        fi
    fi
}

manage_agterm_hooks_conf() {
    local conf_file="$HOME/.config/agterm/hooks.conf"
    local hook_line='on message "$HOME/.local/bin/mailbox-chat.py" agterm-hook'

    if (( UNINSTALL )); then
        if [[ -f "$conf_file" ]]; then
            if grep -q "agterm-agent-tools" "$conf_file"; then
                log_action "Removing agterm-agent-tools block from $conf_file"
                if (( ! DRY_RUN )); then
                    local tmp_conf
                    tmp_conf="$(mktemp)"
                    awk '
                        /# >>> agterm-agent-tools >>>/ { skip=1; next }
                        /# <<< agterm-agent-tools <<</ { skip=0; next }
                        !skip { print }
                    ' "$conf_file" > "$tmp_conf"
                    mv "$tmp_conf" "$conf_file"
                fi
            fi
        fi
        return 0
    fi

    local conf_dir
    conf_dir="$(dirname "$conf_file")"
    if [[ ! -d "$conf_dir" ]]; then
        log_action "Creating directory: $conf_dir"
        if (( ! DRY_RUN )); then
            mkdir -p "$conf_dir"
        fi
    fi

    if [[ -f "$conf_file" ]]; then
        if grep -q "# >>> agterm-agent-tools >>>" "$conf_file" || grep -q 'mailbox-chat\.py"*[[:space:]]*agterm-hook' "$conf_file"; then
            log_action "agterm hooks.conf already contains mailbox-chat hook"
            return 0
        fi
    fi

    log_action "Adding mailbox-chat hook to $conf_file"
    if (( ! DRY_RUN )); then
        cat >> "$conf_file" <<EOF

# >>> agterm-agent-tools >>>
$hook_line
# <<< agterm-agent-tools <<<
EOF
    fi
}

manage_agy_hooks_json() {
    local target_json="$HOME/.gemini/config/hooks.json"
    local fragment_file="$SCRIPT_DIR/config/agy-hooks.json.fragment"
    local manifest_file="$HOME/.local/state/agterm-agent-tools/manifest.json"

    if (( UNINSTALL )); then
        if [[ -f "$manifest_file" ]]; then
            log_action "Removing managed AGY lifecycle hooks via manifest from $target_json"
            if (( ! DRY_RUN )); then
                python3 -c '
import json, sys, os, copy

target_path = sys.argv[1]
manifest_file = sys.argv[2]

if not os.path.exists(manifest_file):
    sys.exit(0)

try:
    with open(manifest_file, "r", encoding="utf-8") as f:
        manifest = json.load(f)
except Exception as e:
    sys.exit(f"Error: Manifest {manifest_file} is corrupted ({e}). Aborting uninstall to protect configurations.")

if not isinstance(manifest, dict):
    sys.exit(f"Error: Manifest {manifest_file} has invalid schema. Aborting uninstall.")

if not os.path.exists(target_path):
    try:
        os.remove(manifest_file)
    except OSError:
        pass
    sys.exit(0)

try:
    with open(target_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    sys.exit(f"Error: Target {target_path} contains unreadable or malformed JSON ({e}). Aborting uninstall.")

if not isinstance(data, dict):
    sys.exit(f"Error: Target {target_path} root is not a JSON object. Aborting uninstall.")

def is_our_hook(item):
    if not isinstance(item, dict):
        return False
    cmd = item.get("command", "")
    if "agy-status-hook.sh" in cmd or "mailbox-chat.py" in cmd:
        return True
    nested = item.get("hooks")
    if isinstance(nested, list):
        for sub in nested:
            if isinstance(sub, dict) and ("agy-status-hook.sh" in sub.get("command", "") or "mailbox-chat.py" in sub.get("command", "")):
                return True
    return False

changed = False

for key in ["agterm-status", "mailbox-chat"]:
    if key in data:
        group = data[key]
        if isinstance(group, dict):
            clean_key = key.replace("-", "_")
            orig_group = manifest.get("original_" + clean_key)
            was_created = manifest.get("created_" + clean_key, False)
            for event_name in list(group.keys()):
                if isinstance(group[event_name], list):
                    filtered = [h for h in group[event_name] if not is_our_hook(h)]
                    if len(filtered) != len(group[event_name]):
                        changed = True
                    if filtered:
                        group[event_name] = filtered
                    else:
                        if isinstance(orig_group, dict) and event_name in orig_group:
                            group[event_name] = []
                        else:
                            del group[event_name]
                            changed = True
            # If nothing remains and group was created by our installer, remove the group
            if was_created and not group:
                del data[key]
                changed = True
            elif orig_group is not None and not group:
                data[key] = copy.deepcopy(orig_group)
                changed = True

if changed:
    tmp_target = f"{target_path}.tmp.{os.getpid()}"
    with open(tmp_target, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_target, target_path)

try:
    os.remove(manifest_file)
except OSError:
    pass
' "$target_json" "$manifest_file"
            fi
        fi
        return 0
    fi

    local target_dir
    target_dir="$(dirname "$target_json")"
    if [[ ! -d "$target_dir" ]]; then
        log_action "Creating directory: $target_dir"
        if (( ! DRY_RUN )); then
            mkdir -p "$target_dir"
        fi
    fi

    log_action "Merging AGY lifecycle hooks into $target_json"
    if (( ! DRY_RUN )); then
        python3 -c '
import json, sys, shutil, time, uuid, os, copy

target_path = sys.argv[1]
fragment_path = sys.argv[2]
manifest_file = sys.argv[3]

try:
    with open(fragment_path, "r", encoding="utf-8") as f:
        frag = json.load(f)
except Exception as e:
    sys.exit(f"Failed to load fragment {fragment_path}: {e}")

data = {}
file_existed = False
if os.path.exists(target_path):
    file_existed = True
    with open(target_path, "r", encoding="utf-8") as f:
        content = f.read()
    if content.strip():
        try:
            data = json.loads(content)
        except Exception as e:
            sys.exit(f"Error: {target_path} contains malformed or unreadable JSON ({e}). Aborting install to prevent data loss.")

def is_our_hook(item):
    if not isinstance(item, dict):
        return False
    cmd = item.get("command", "")
    if "agy-status-hook.sh" in cmd or "mailbox-chat.py" in cmd:
        return True
    nested = item.get("hooks")
    if isinstance(nested, list):
        for sub in nested:
            if isinstance(sub, dict) and ("agy-status-hook.sh" in sub.get("command", "") or "mailbox-chat.py" in sub.get("command", "")):
                return True
    return False

def group_has_our_hooks(group, frag_group):
    if not isinstance(group, dict):
        return False
    for event_name, hook_list in frag_group.items():
        if event_name not in group or not isinstance(group[event_name], list):
            return False
        for expected in hook_list:
            if expected not in group[event_name]:
                return False
    return True

already_up_to_date = (
    group_has_our_hooks(data.get("agterm-status"), frag.get("agterm-status", {})) and
    group_has_our_hooks(data.get("mailbox-chat"), frag.get("mailbox-chat", {}))
)

if already_up_to_date and os.path.exists(manifest_file):
    sys.exit(0)

# Load existing manifest if present to preserve initial pre-install values on reinstall
existing_manifest = {}
if os.path.exists(manifest_file):
    try:
        with open(manifest_file, "r", encoding="utf-8") as f:
            existing_manifest = json.load(f)
    except Exception:
        existing_manifest = {}

# Create unique exclusive backup before mutating existing configuration
if file_existed and data:
    backup_path = f"{target_path}.bak.{int(time.time())}_{uuid.uuid4().hex[:8]}"
    try:
        shutil.copy2(target_path, backup_path)
    except Exception as e:
        sys.exit(f"Error: Failed to create backup at {backup_path}: {e}. Aborting install.")

# Record manifest with original pre-install values
os.makedirs(os.path.dirname(manifest_file), exist_ok=True)
manifest = {
    "file_existed": existing_manifest.get("file_existed", file_existed),
    "original_agterm_status": existing_manifest.get("original_agterm_status", copy.deepcopy(data.get("agterm-status"))),
    "original_mailbox_chat": existing_manifest.get("original_mailbox_chat", copy.deepcopy(data.get("mailbox-chat"))),
    "created_agterm_status": existing_manifest.get("created_agterm_status", "agterm-status" not in data),
    "created_mailbox_chat": existing_manifest.get("created_mailbox_chat", "mailbox-chat" not in data),
    "installed_at": existing_manifest.get("installed_at", int(time.time())),
    "updated_at": int(time.time())
}

tmp_manifest = f"{manifest_file}.tmp.{uuid.uuid4().hex}"
with open(tmp_manifest, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
os.replace(tmp_manifest, manifest_file)

# Surgical merge: preserve custom keys inside each group, append our hooks to list
for key, frag_group in frag.items():
    if key not in data or not isinstance(data[key], dict):
        data[key] = copy.deepcopy(frag_group)
    else:
        for event_name, hook_list in frag_group.items():
            if event_name not in data[key] or not isinstance(data[key][event_name], list):
                data[key][event_name] = copy.deepcopy(hook_list)
            else:
                for h in hook_list:
                    if h not in data[key][event_name]:
                        data[key][event_name].append(copy.deepcopy(h))

tmp_target = f"{target_path}.tmp.{uuid.uuid4().hex}"
with open(tmp_target, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp_target, target_path)
' "$target_json" "$fragment_file" "$manifest_file"
    fi
}

manage_codex_hooks() {
    local codex_dir="$HOME/.codex"
    local codex_conf="$codex_dir/config.toml"

    if [[ ! -d "$codex_dir" ]]; then
        return 0
    fi

    if (( UNINSTALL )); then
        if [[ -f "$codex_conf" ]] && grep -q "# >>> agterm-agent-tools >>>" "$codex_conf"; then
            log_action "Removing agterm-agent-tools block from $codex_conf"
            if (( ! DRY_RUN )); then
                local tmp_toml
                tmp_toml="$(mktemp)"
                awk '
                    /# >>> agterm-agent-tools >>>/ { skip=1; next }
                    /# <<< agterm-agent-tools <<</ { skip=0; next }
                    !skip { print }
                ' "$codex_conf" > "$tmp_toml"
                mv "$tmp_toml" "$codex_conf"
            fi
        fi
        return 0
    fi

    if [[ -f "$codex_conf" ]]; then
        if grep -q "# >>> agterm-agent-tools >>>" "$codex_conf"; then
            log_action "Codex config.toml already contains agterm-agent-tools block"
            return 0
        fi
    fi

    log_action "Configuring Codex lifecycle & mailbox hooks in $codex_conf"
    if (( ! DRY_RUN )); then
        local user_home="$HOME"
        cat >> "$codex_conf" <<EOF

# >>> agterm-agent-tools >>>
[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type = "command"
command = "'$user_home/.config/agterm/agent-status/agterm-codex-status.sh' session-start"

[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type = "command"
command = "\"$user_home/.local/bin/mailbox-chat.py\" codex-hook"

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "'$user_home/.config/agterm/agent-status/agterm-codex-status.sh' user-prompt-submit"

[[hooks.PreToolUse]]
[[hooks.PreToolUse.hooks]]
type = "command"
command = "'$user_home/.config/agterm/agent-status/agterm-codex-status.sh' pre-tool-use"

[[hooks.PostToolUse]]
[[hooks.PostToolUse.hooks]]
type = "command"
command = "'$user_home/.config/agterm/agent-status/agterm-codex-status.sh' post-tool-use"

[[hooks.PermissionRequest]]
[[hooks.PermissionRequest.hooks]]
type = "command"
command = "'$user_home/.config/agterm/agent-status/agterm-codex-status.sh' permission-request"

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "'$user_home/.config/agterm/agent-status/agterm-codex-status.sh' stop"
# <<< agterm-agent-tools <<<
EOF
    fi
}

reload_agterm() {
    if command -v agtermctl >/dev/null 2>&1; then
        log_action "Reloading agterm hooks via agtermctl"
        if (( ! DRY_RUN )); then
            agtermctl hooks reload 2>/dev/null || true
        fi
    fi
}

main() {
    if (( UNINSTALL )); then
        log_info "Uninstalling agterm-agent-tools..."
    elif (( DRY_RUN )); then
        log_info "Simulating installation (dry run)..."
    else
        log_info "Installing agterm-agent-tools..."
    fi

    if (( UNINSTALL )); then
        # On uninstall: run configuration cleanup first as preflight
        log_info "Managing configurations (preflight check)..."
        manage_agy_hooks_json
        manage_codex_hooks
        manage_agterm_hooks_conf

        log_info "Managing agent skills..."
        make_symlink "$SCRIPT_DIR/skills/agy/mailbox-chat"   "$HOME/.gemini/config/skills/mailbox-chat"
        make_symlink "$SCRIPT_DIR/skills/codex/mailbox-chat" "$HOME/.codex/skills/mailbox-chat"

        log_info "Managing hook scripts..."
        make_symlink "$SCRIPT_DIR/hooks/agy/agy-status-hook.sh"        "$HOME/.config/agterm/hooks/agy/agy-status-hook.sh"
        make_symlink "$SCRIPT_DIR/hooks/agterm/agterm-agent-status.sh" "$HOME/.config/agterm/agent-status/agterm-agent-status.sh"
        make_symlink "$SCRIPT_DIR/hooks/agterm/agterm-codex-status.sh" "$HOME/.config/agterm/agent-status/agterm-codex-status.sh"

        log_info "Managing CLI binaries (~/.local/bin)..."
        make_symlink "$SCRIPT_DIR/bin/mailbox-chat.py" "$HOME/.local/bin/mailbox-chat.py"
        make_symlink "$SCRIPT_DIR/bin/codex-mailbox"   "$HOME/.local/bin/codex-mailbox"

        reload_agterm
        log_info "Uninstallation complete."
        return 0
    fi

    # 1. Binaries
    log_info "Managing CLI binaries (~/.local/bin)..."
    make_symlink "$SCRIPT_DIR/bin/mailbox-chat.py" "$HOME/.local/bin/mailbox-chat.py"
    make_symlink "$SCRIPT_DIR/bin/codex-mailbox"   "$HOME/.local/bin/codex-mailbox"

    # 2. Hooks
    log_info "Managing hook scripts..."
    make_symlink "$SCRIPT_DIR/hooks/agy/agy-status-hook.sh"        "$HOME/.config/agterm/hooks/agy/agy-status-hook.sh"
    make_symlink "$SCRIPT_DIR/hooks/agterm/agterm-agent-status.sh" "$HOME/.config/agterm/agent-status/agterm-agent-status.sh"
    make_symlink "$SCRIPT_DIR/hooks/agterm/agterm-codex-status.sh" "$HOME/.config/agterm/agent-status/agterm-codex-status.sh"

    # 3. Skills
    log_info "Managing agent skills..."
    make_symlink "$SCRIPT_DIR/skills/agy/mailbox-chat"   "$HOME/.gemini/config/skills/mailbox-chat"
    if [[ -d "$HOME/.codex" ]]; then
        make_symlink "$SCRIPT_DIR/skills/codex/mailbox-chat" "$HOME/.codex/skills/mailbox-chat"
    fi

    # 4. Configurations
    log_info "Managing configurations..."
    manage_agterm_hooks_conf
    manage_agy_hooks_json
    manage_codex_hooks

    # 5. Reload
    reload_agterm

    if (( DRY_RUN )); then
        log_info "Dry run complete. No files were modified."
    else
        log_info "Installation complete! All tools and hooks are active."
    fi
}

main "$@"

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

Install or uninstall agterm-agent-tools (mailbox-chat, status/safety hooks, skills).

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
      ~/.config/agterm/hooks/agy/safety-guard.py           -> hooks/agy/safety-guard.py
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

log_error() {
    printf "Error: %s\n" "$*" >&2
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

preflight_validation() {
    local target_json="$HOME/.gemini/config/hooks.json"
    local manifest_file="$HOME/.local/state/agterm-agent-tools/manifest.json"

    # 1. Validate manifest if present
    if [[ -f "$manifest_file" ]]; then
        python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if not content.strip():
        raise ValueError("Manifest is empty")
    data = json.loads(content)
    if not isinstance(data, dict):
        raise ValueError("Manifest root must be an object")
except Exception as e:
    sys.exit(f"Error: Manifest {path} is corrupted ({e}). Aborting before making any system changes.")
' "$manifest_file"
    fi

    # 2. Validate hooks.json if present
    if [[ -f "$target_json" ]]; then
        python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if content.strip():
        data = json.loads(content)
        if not isinstance(data, dict):
            raise ValueError("hooks.json root must be an object")
except Exception as e:
    sys.exit(f"Error: {path} contains malformed or unreadable JSON ({e}). Aborting before making any system changes.")
' "$target_json"
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

manage_safety_guard_symlink() {
    local src="$SCRIPT_DIR/hooks/agy/safety-guard.py"
    local dest="$HOME/.config/agterm/hooks/agy/safety-guard.py"
    local target_json="$HOME/.gemini/config/hooks.json"

    # Do not break a pre-existing/user-preserved hook during uninstall.
    if (( UNINSTALL )) && [[ -f "$target_json" ]] && python3 -c '
import json, sys

def references_guard(obj):
    if isinstance(obj, dict):
        command = obj.get("command", "")
        if isinstance(command, str) and ".config/agterm/hooks/agy/safety-guard.py" in command:
            return True
        return any(references_guard(value) for value in obj.values())
    if isinstance(obj, list):
        return any(references_guard(value) for value in obj)
    return False

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
sys.exit(0 if references_guard(data) else 1)
' "$target_json"; then
        log_action "Preserving safety-guard symlink: a remaining hook still references it."
        return 0
    fi
    make_symlink "$src" "$dest"
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
                local py_status=0
                python3 -c '
import json, sys, os, copy, itertools

target_path = sys.argv[1]
fragment_path = sys.argv[2]
manifest_file = sys.argv[3]
home = os.environ.get("HOME", "")

if not os.path.exists(manifest_file):
    sys.exit(0)

try:
    with open(manifest_file, "r", encoding="utf-8") as f:
        content = f.read()
    if not content.strip():
        raise ValueError("Manifest is empty")
    manifest = json.loads(content)
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

MANAGED_BIN_RELPATHS = {
    ".config/agterm/hooks/agy/agy-status-hook.sh": "agy-status-hook.sh",
    ".config/agterm/hooks/agy/safety-guard.py": "safety-guard.py",
    ".local/bin/mailbox-chat.py": "mailbox-chat.py",
}

MANAGED_ACTIONS = {
    "agy-status-hook.sh": {"invocation", "ask", "tool-done", "stop"},
    "safety-guard.py": {""},
    "mailbox-chat.py": {"agy-hook"},
}

LEGACY_ACTIONS = {
    "agy-status-hook.sh": {
        "old-stop": "stop",
    },
    "mailbox-chat.py": {},
}

def get_managed_hook_info(cmd_str):
    if not isinstance(cmd_str, str):
        return None
    words = cmd_str.strip().split()
    if not words:
        return None
    raw_bin = words[0].strip("\"'\''")
    if home:
        if raw_bin.startswith(home):
            raw_bin = "$HOME" + raw_bin[len(home):]
        elif raw_bin.startswith("${HOME}"):
            raw_bin = "$HOME" + raw_bin[len("${HOME}"):]

    bin_name = None
    if raw_bin.startswith("$HOME/"):
        rel = raw_bin[len("$HOME/"):]
        if rel in MANAGED_BIN_RELPATHS:
            bin_name = MANAGED_BIN_RELPATHS[rel]
    if not bin_name:
        return None

    action = words[1].strip("\"'\''") if len(words) > 1 else ""
    if action in MANAGED_ACTIONS.get(bin_name, set()):
        return {
            "binary": bin_name,
            "action": action,
            "canonical": action,
            "is_legacy": False
        }
    if action in LEGACY_ACTIONS.get(bin_name, {}):
        return {
            "binary": bin_name,
            "action": action,
            "canonical": LEGACY_ACTIONS[bin_name][action],
            "is_legacy": True
        }
    return None

def get_hook_kind(h):
    if not isinstance(h, dict) or "command" not in h:
        return None
    info = get_managed_hook_info(h["command"])
    if info:
        return ("managed", info["binary"], info["canonical"])
    return "custom"

def score_matcher_similarity(curr_m, orig_m):
    curr_subs = curr_m.get("hooks", []) if isinstance(curr_m.get("hooks"), list) else []
    orig_subs = orig_m.get("hooks", []) if isinstance(orig_m.get("hooks"), list) else []
    score = 0
    if curr_m == orig_m:
        score += 10000

    curr_kinds = [get_hook_kind(h) for h in curr_subs]
    orig_kinds = [get_hook_kind(h) for h in orig_subs]

    # Exact kind sequence match
    if curr_kinds == orig_kinds:
        score += 1500
    # Prefix match
    elif len(orig_kinds) <= len(curr_kinds) and curr_kinds[:len(orig_kinds)] == orig_kinds:
        score += 800

    # Custom command position match
    curr_has_custom = "custom" in curr_kinds
    orig_has_custom = "custom" in orig_kinds
    if curr_has_custom and orig_has_custom:
        score += 200
        if curr_kinds.index("custom") == orig_kinds.index("custom"):
            score += 400
    elif not curr_has_custom and not orig_has_custom:
        score += 200

    for c_idx, cs in enumerate(curr_subs):
        if not isinstance(cs, dict):
            if cs in orig_subs:
                score += 100
            continue
        cs_info = get_managed_hook_info(cs.get("command", ""))
        if cs in orig_subs:
            o_idx = orig_subs.index(cs)
            if not cs_info:
                score += 2000
                if c_idx == o_idx:
                    score += 500
            else:
                score += 200
                if c_idx == o_idx:
                    score += 500
        elif "command" in cs:
            for o_idx, os_item in enumerate(orig_subs):
                if isinstance(os_item, dict) and "command" in os_item:
                    os_info = get_managed_hook_info(os_item["command"])
                    if cs_info and os_info:
                        if cs_info["binary"] == os_info["binary"] and cs_info["canonical"] == os_info["canonical"]:
                            score += 50
                            if c_idx == o_idx:
                                score += 50
                    elif not cs_info and not os_info:
                        if cs["command"] == os_item["command"]:
                            score += 1500
                            if c_idx == o_idx:
                                score += 300
    return score

def reconcile_hook_list(curr_list, orig_list):
    curr_list = curr_list if isinstance(curr_list, list) else []
    orig_list = orig_list if isinstance(orig_list, list) else []
    orig_consumed = [False] * len(orig_list)
    res = []

    for curr_item in curr_list:
        if not isinstance(curr_item, dict):
            res.append(copy.deepcopy(curr_item))
            continue

        # 1. Exact match check
        exact_idx = -1
        for i, om in enumerate(orig_list):
            if not orig_consumed[i] and om == curr_item:
                exact_idx = i
                break
        if exact_idx != -1:
            orig_consumed[exact_idx] = True
            res.append(copy.deepcopy(curr_item))
            continue

        # 2. Matcher handling
        if "matcher" in curr_item and isinstance(curr_item.get("hooks"), list):
            best_idx = -1
            best_score = -1
            for i, om in enumerate(orig_list):
                if not orig_consumed[i] and isinstance(om, dict) and om.get("matcher") == curr_item.get("matcher"):
                    s = score_matcher_similarity(curr_item, om)
                    if s > best_score:
                        best_score = s
                        best_idx = i

            orig_subs = []
            if best_idx != -1:
                orig_consumed[best_idx] = True
                orig_subs = orig_list[best_idx].get("hooks", []) if isinstance(orig_list[best_idx].get("hooks"), list) else []

            filtered_subs = reconcile_hook_list(curr_item["hooks"], orig_subs)
            if filtered_subs:
                m_copy = copy.deepcopy(curr_item)
                m_copy["hooks"] = filtered_subs
                res.append(m_copy)
            continue

        # 3. Direct command hook handling
        if "command" in curr_item:
            info = get_managed_hook_info(curr_item["command"])
            if not info:
                # Custom user command or foreign tool: keep current definition untouched
                res.append(copy.deepcopy(curr_item))
            else:
                legacy_idx = -1
                for i, om in enumerate(orig_list):
                    if not orig_consumed[i] and isinstance(om, dict) and "command" in om:
                        om_info = get_managed_hook_info(om["command"])
                        if om_info and om_info["binary"] == info["binary"] and om_info["canonical"] == info["canonical"]:
                            legacy_idx = i
                            break
                if legacy_idx != -1:
                    orig_consumed[legacy_idx] = True
                    om_info = get_managed_hook_info(orig_list[legacy_idx]["command"])
                    if om_info and om_info["is_legacy"]:
                        res.append(copy.deepcopy(orig_list[legacy_idx]))
                    else:
                        res.append(copy.deepcopy(curr_item))
                else:
                    # Added by our installer: drop it
                    pass
        else:
            res.append(copy.deepcopy(curr_item))

    return res

uninstall_event_list = reconcile_hook_list

def derive_mutations(manifest, frag, home):
    mutations = []
    orig_status = manifest.get("original_agterm_status")
    orig_chat = manifest.get("original_mailbox_chat")
    orig = {
        "agterm-status": orig_status if isinstance(orig_status, dict) else {},
        "mailbox-chat": orig_chat if isinstance(orig_chat, dict) else {},
        "safety-guard": manifest.get("original_safety_guard") or {}
    }

    for key, frag_group in frag.items():
        # Older manifests do not own groups introduced by a later installer.
        if "original_" + key.replace("-", "_") not in manifest:
            continue
        if not isinstance(frag_group, dict):
            continue
        orig_group = orig.get(key, {})
        for event_name, hook_list in frag_group.items():
            if not isinstance(hook_list, list):
                continue
            orig_event_list = orig_group.get(event_name, []) if isinstance(orig_group, dict) else []
            for h in hook_list:
                if not isinstance(h, dict):
                    continue
                if "command" in h:
                    h_info = get_managed_hook_info(h["command"])
                    if not h_info:
                        continue
                    found_orig = False
                    for om in orig_event_list:
                        if isinstance(om, dict) and "command" in om:
                            om_info = get_managed_hook_info(om["command"])
                            if om_info and om_info["binary"] == h_info["binary"] and om_info["canonical"] == h_info["canonical"]:
                                if om_info["is_legacy"]:
                                    mutations.append({"type": "upgrade_direct", "key": key, "event": event_name, "from": copy.deepcopy(om), "to": copy.deepcopy(h)})
                                found_orig = True
                                break
                    if not found_orig:
                        mutations.append({"type": "add_direct", "key": key, "event": event_name, "hook": copy.deepcopy(h)})
                elif "matcher" in h and "hooks" in h:
                    pattern = h.get("matcher")
                    matching_orig = [
                        (idx, om) for idx, om in enumerate(orig_event_list)
                        if isinstance(om, dict) and om.get("matcher") == pattern
                    ]
                    if not matching_orig:
                        mutations.append({"type": "add_matcher", "key": key, "event": event_name, "matcher": copy.deepcopy(h)})
                    else:
                        for sub_h in h.get("hooks", []):
                            sub_info = get_managed_hook_info(sub_h.get("command", ""))
                            if not sub_info:
                                continue
                            first_m_idx, first_m = matching_orig[0]
                            first_has = any(
                                isinstance(sh, dict) and (get_managed_hook_info(sh.get("command", "")) or {}).get("canonical") == sub_info["canonical"]
                                for sh in first_m.get("hooks", [])
                            )
                            if not first_has:
                                first_subs = first_m.get("hooks", []) if isinstance(first_m.get("hooks"), list) else []
                                mutations.append({"type": "add_sub", "key": key, "event": event_name, "pattern": pattern, "hook": copy.deepcopy(sub_h), "target_hooks": copy.deepcopy(first_subs)})
    return mutations

def rollback_mutations(data, manifest):
    mutations = manifest.get("mutations", [])
    if not mutations:
        return False

    changed = False
    orig_status = manifest.get("original_agterm_status") or {}
    orig_chat = manifest.get("original_mailbox_chat") or {}

    for m in reversed(mutations):
        m_type = m.get("type")
        key = m.get("key")
        event = m.get("event")
        if key not in data or not isinstance(data[key], dict):
            continue
        if event not in data[key] or not isinstance(data[key][event], list):
            continue

        if m_type == "add_direct":
            h_info = get_managed_hook_info(m["hook"].get("command", ""))
            if not h_info:
                continue
            for idx, curr_h in enumerate(data[key][event]):
                if isinstance(curr_h, dict) and "command" in curr_h:
                    c_info = get_managed_hook_info(curr_h["command"])
                    if c_info and c_info["binary"] == h_info["binary"] and c_info["canonical"] == h_info["canonical"]:
                        del data[key][event][idx]
                        changed = True
                        break
        elif m_type == "upgrade_direct":
            h_info = get_managed_hook_info(m["to"].get("command", ""))
            if not h_info:
                continue
            for idx, curr_h in enumerate(data[key][event]):
                if isinstance(curr_h, dict) and "command" in curr_h:
                    c_info = get_managed_hook_info(curr_h["command"])
                    if c_info and c_info["binary"] == h_info["binary"] and c_info["canonical"] == h_info["canonical"]:
                        data[key][event][idx]["command"] = m["from"]["command"]
                        changed = True
                        break
        elif m_type == "add_matcher":
            pattern = m["matcher"].get("matcher")
            m_hooks = m["matcher"].get("hooks", [])
            m_managed_canonicals = set()
            for mh in m_hooks:
                if isinstance(mh, dict) and "command" in mh:
                    info = get_managed_hook_info(mh["command"])
                    if info:
                        m_managed_canonicals.add((info["binary"], info["canonical"]))

            target_idx = -1
            for idx, curr_m in enumerate(data[key][event]):
                if isinstance(curr_m, dict) and curr_m.get("matcher") == pattern:
                    curr_canonicals = set()
                    for sh in curr_m.get("hooks", []):
                        if isinstance(sh, dict) and "command" in sh:
                            info = get_managed_hook_info(sh["command"])
                            if info:
                                curr_canonicals.add((info["binary"], info["canonical"]))
                    if m_managed_canonicals and m_managed_canonicals.issubset(curr_canonicals):
                        target_idx = idx
                        break
                    elif not m_managed_canonicals and curr_m == m["matcher"]:
                        target_idx = idx
                        break

            if target_idx != -1:
                curr_m = data[key][event][target_idx]
                has_custom = any(
                    isinstance(sh, dict) and not get_managed_hook_info(sh.get("command", ""))
                    for sh in curr_m.get("hooks", [])
                )
                if not has_custom:
                    del data[key][event][target_idx]
                    changed = True
                else:
                    curr_m["hooks"] = [
                        sh for sh in curr_m.get("hooks", [])
                        if not (isinstance(sh, dict) and get_managed_hook_info(sh.get("command", "")))
                    ]
                    changed = True
        elif m_type == "add_sub":
            pattern = m["pattern"]
            sub_info = get_managed_hook_info(m["hook"].get("command", ""))
            if not sub_info:
                continue

            orig_group = manifest.get("original_" + key.replace("-", "_")) or {}
            orig_event_list = orig_group.get(event, []) if isinstance(orig_group, dict) else []
            orig_matchers = [
                om for om in orig_event_list
                if isinstance(om, dict) and om.get("matcher") == pattern and isinstance(om.get("hooks"), list)
            ]

            curr_matchers = [
                (c_idx, cm) for c_idx, cm in enumerate(data[key][event])
                if isinstance(cm, dict) and cm.get("matcher") == pattern and isinstance(cm.get("hooks"), list)
            ]

            target_hooks = m.get("target_hooks")

            # Check hook count: if remaining occurrences <= original occurrences,
            # the addition was already deleted by the user. Do not delete original children.
            orig_canonical_count = sum(
                1 for om in orig_matchers
                for oh in (om.get("hooks", []) if isinstance(om.get("hooks"), list) else [])
                if isinstance(oh, dict) and "command" in oh and
                (get_managed_hook_info(oh["command"]) or {}).get("canonical") == sub_info["canonical"]
            )
            curr_canonical_count = sum(
                1 for c_idx, cm in curr_matchers
                for ch in (cm.get("hooks", []) if isinstance(cm.get("hooks"), list) else [])
                if isinstance(ch, dict) and "command" in ch and
                (get_managed_hook_info(ch["command"]) or {}).get("canonical") == sub_info["canonical"]
            )
            if curr_canonical_count <= orig_canonical_count:
                continue

            n_curr = len(curr_matchers)
            n_orig = len(orig_matchers)

            # Filter out untouched matchers that are identical between current and original
            unmatched_orig = list(orig_matchers)
            rel_curr = []
            for c_idx, cm in curr_matchers:
                matched_om = None
                for om in unmatched_orig:
                    if cm == om:
                        matched_om = om
                        break
                if matched_om is not None:
                    unmatched_orig.remove(matched_om)
                else:
                    rel_curr.append((c_idx, cm))

            if len(rel_curr) < len(curr_matchers) and rel_curr and unmatched_orig:
                curr_matchers = rel_curr
                orig_matchers = unmatched_orig
                n_curr = len(curr_matchers)
                n_orig = len(orig_matchers)

            # If still above exact-search limit, safely abort to preserve configuration
            if n_curr > 6 or n_orig > 6:
                sys.exit(10)

            best_score = -1
            best_mappings = []

            perm_gen = (
                (list(zip(range(n_curr), subset)))
                if n_curr <= n_orig
                else (list(zip(subset, range(n_orig))))
                for subset in (itertools.permutations(range(n_orig), n_curr) if n_curr <= n_orig else itertools.permutations(range(n_curr), n_orig))
            )
            for mapping in perm_gen:
                tot = 0
                for c_i, o_i in mapping:
                    s = score_matcher_similarity(curr_matchers[c_i][1], orig_matchers[o_i])
                    if target_hooks is not None:
                        c_h = curr_matchers[c_i][1].get("hooks", [])
                        if any(th in c_h for th in target_hooks):
                            s += 1000
                    tot += s
                if tot > best_score:
                    best_score = tot
                    best_mappings = [mapping]
                elif tot == best_score:
                    best_mappings.append(mapping)

            if not best_mappings:
                continue

            def get_target_for_mapping(mapping):
                paired_curr_to_orig = {c_i: o_i for c_i, o_i in mapping}
                protected_sub_hooks = set()
                for c_i, (c_idx, cm) in enumerate(curr_matchers):
                    if c_i in paired_curr_to_orig:
                        o_i = paired_curr_to_orig[c_i]
                        om = orig_matchers[o_i]
                        orig_hooks = []
                        for oh in om.get("hooks", []):
                            if isinstance(oh, dict) and "command" in oh:
                                oh_info = get_managed_hook_info(oh["command"])
                                if oh_info and oh_info["binary"] == sub_info["binary"] and oh_info["canonical"] == sub_info["canonical"]:
                                    orig_hooks.append(oh)
                        unconsumed_oh = list(orig_hooks)
                        for s_idx, sh in enumerate(cm.get("hooks", [])):
                            if isinstance(sh, dict) and "command" in sh:
                                sh_info = get_managed_hook_info(sh["command"])
                                if sh_info and sh_info["binary"] == sub_info["binary"] and sh_info["canonical"] == sub_info["canonical"]:
                                    if sh in unconsumed_oh:
                                        protected_sub_hooks.add((c_idx, s_idx))
                                        unconsumed_oh.remove(sh)
                        for s_idx, sh in enumerate(cm.get("hooks", [])):
                            if (c_idx, s_idx) not in protected_sub_hooks and isinstance(sh, dict) and "command" in sh:
                                sh_info = get_managed_hook_info(sh["command"])
                                if sh_info and sh_info["binary"] == sub_info["binary"] and sh_info["canonical"] == sub_info["canonical"]:
                                    if unconsumed_oh:
                                        protected_sub_hooks.add((c_idx, s_idx))
                                        unconsumed_oh.pop(0)

                best_t_m = None
                best_t_c_idx = -1
                best_t_s = -1
                best_c_score = -1

                for c_i, (c_idx, cm) in enumerate(curr_matchers):
                    m_affinity = 0
                    if target_hooks is not None:
                        cm_hooks = cm.get("hooks", [])
                        matches = sum(1 for th in target_hooks if th in cm_hooks)
                        m_affinity += matches * 100
                    if c_i in paired_curr_to_orig:
                        om = orig_matchers[paired_curr_to_orig[c_i]]
                        om_has_canonical = any(
                            isinstance(oh, dict) and (get_managed_hook_info(oh.get("command", "")) or {}).get("canonical") == sub_info["canonical"]
                            for oh in om.get("hooks", [])
                        )
                        if not om_has_canonical:
                            m_affinity += 500

                    for s_idx, sh in enumerate(cm.get("hooks", [])):
                        if (c_idx, s_idx) in protected_sub_hooks:
                            continue
                        if isinstance(sh, dict) and "command" in sh:
                            sh_info = get_managed_hook_info(sh["command"])
                            if sh_info and sh_info["binary"] == sub_info["binary"] and sh_info["canonical"] == sub_info["canonical"]:
                                if sh.get("timeout") == m["hook"].get("timeout"):
                                    if m_affinity > best_c_score:
                                        best_c_score = m_affinity
                                        best_t_m = cm
                                        best_t_c_idx = c_idx
                                        best_t_s = s_idx
                return (best_t_m, best_t_c_idx, best_t_s, best_c_score)

            targets = set()
            target_results = []
            for mapping in best_mappings:
                res = get_target_for_mapping(mapping)
                if res[0] is not None and res[2] != -1 and res[3] > 0:
                    targets.add((res[1], res[2]))
                    target_results.append(res)
            if len(targets) > 1:
                # Ambiguous tied ownership detected across plausible assignments!
                # Abort before destructive changes to preserve user configuration.
                sys.exit(10)
            elif len(targets) == 1:
                t_m, t_c_idx, t_s, t_score = target_results[0]
                del t_m["hooks"][t_s]
                changed = True
        elif m_type == "upgrade_sub":
            pattern = m["pattern"]
            sub_info = get_managed_hook_info(m["to"].get("command", ""))
            if not sub_info:
                continue
            for curr_m in data[key][event]:
                if isinstance(curr_m, dict) and curr_m.get("matcher") == pattern and isinstance(curr_m.get("hooks"), list):
                    for s_idx, s_h in enumerate(curr_m["hooks"]):
                        if isinstance(s_h, dict) and "command" in s_h:
                            s_info = get_managed_hook_info(s_h["command"])
                            if s_info and s_info["binary"] == sub_info["binary"] and s_info["canonical"] == sub_info["canonical"]:
                                curr_m["hooks"][s_idx]["command"] = m["from"]["command"]
                                changed = True
                                break

    # Clean up empty matchers, events, and groups
    for key in ["agterm-status", "mailbox-chat", "safety-guard"]:
        if "original_" + key.replace("-", "_") not in manifest:
            continue
        if key in data and isinstance(data[key], dict):
            clean_key = key.replace("-", "_")
            orig_group = manifest.get("original_" + clean_key)
            was_created = manifest.get("created_" + clean_key, False)
            for event in list(data[key].keys()):
                if isinstance(data[key][event], list):
                    data[key][event] = [
                        item for item in data[key][event]
                        if not (isinstance(item, dict) and "matcher" in item and "hooks" in item and not item["hooks"])
                    ]
                    if not data[key][event]:
                        if isinstance(orig_group, dict) and event in orig_group and orig_group[event] == []:
                            pass
                        else:
                            del data[key][event]
                            changed = True

            if was_created and not data[key]:
                del data[key]
                changed = True

    return changed

changed = False

if "mutations" not in manifest:
    try:
        with open(fragment_path, "r", encoding="utf-8") as f:
            frag = json.load(f)
        manifest["mutations"] = derive_mutations(manifest, frag, home)
    except Exception:
        pass

if manifest.get("mutations"):
    changed = rollback_mutations(data, manifest)
else:
    for key in ["agterm-status", "mailbox-chat", "safety-guard"]:
        if "original_" + key.replace("-", "_") not in manifest:
            continue
        if key in data:
            group = data[key]
            if isinstance(group, dict):
                clean_key = key.replace("-", "_")
                orig_group = manifest.get("original_" + clean_key)
                was_created = manifest.get("created_" + clean_key, False)
                for event_name in list(group.keys()):
                    if isinstance(group[event_name], list):
                        orig_event_list = orig_group.get(event_name, []) if isinstance(orig_group, dict) else []
                        new_event_list = uninstall_event_list(group[event_name], orig_event_list)

                        if new_event_list:
                            if new_event_list != group[event_name]:
                                group[event_name] = new_event_list
                                changed = True
                        else:
                            if isinstance(orig_group, dict) and event_name in orig_group and orig_group[event_name] == []:
                                if group[event_name] != []:
                                    group[event_name] = []
                                    changed = True
                            else:
                                del group[event_name]
                                changed = True

                if was_created and not group:
                    del data[key]
                    changed = True

if changed:
    if not manifest.get("file_existed", True) and not data:
        try:
            os.remove(target_path)
        except OSError:
            pass
    else:
        tmp_target = f"{target_path}.tmp.{os.getpid()}"
        with open(tmp_target, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp_target, target_path)

try:
    os.remove(manifest_file)
except OSError:
    pass
' "$target_json" "$fragment_file" "$manifest_file" || py_status=$?
                if (( py_status == 10 )); then
                    log_action "Ambiguous mutation ownership detected; safely preserving configuration, manifest, and symlinks."
                    exit 0
                elif (( py_status != 0 )); then
                    log_error "Error rolling back hooks (exit code $py_status)"
                    return 1
                fi
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
home = os.environ.get("HOME", "")

existing_manifest = {}
if os.path.exists(manifest_file):
    try:
        with open(manifest_file, "r", encoding="utf-8") as f:
            content = f.read()
        if not content.strip():
            raise ValueError("Manifest is empty")
        existing_manifest = json.loads(content)
        if not isinstance(existing_manifest, dict):
            raise ValueError("Manifest root must be a JSON object")
    except Exception as e:
        sys.exit(f"Error: Manifest {manifest_file} is corrupted ({e}). Aborting install to preserve recovery evidence.")

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

MANAGED_BIN_RELPATHS = {
    ".config/agterm/hooks/agy/agy-status-hook.sh": "agy-status-hook.sh",
    ".config/agterm/hooks/agy/safety-guard.py": "safety-guard.py",
    ".local/bin/mailbox-chat.py": "mailbox-chat.py",
}

MANAGED_ACTIONS = {
    "agy-status-hook.sh": {"invocation", "ask", "tool-done", "stop"},
    "safety-guard.py": {""},
    "mailbox-chat.py": {"agy-hook"},
}

LEGACY_ACTIONS = {
    "agy-status-hook.sh": {
        "old-stop": "stop",
    },
    "mailbox-chat.py": {},
}

def get_managed_hook_info(cmd_str):
    if not isinstance(cmd_str, str):
        return None
    words = cmd_str.strip().split()
    if not words:
        return None
    raw_bin = words[0].strip("\"'\''")
    if home:
        if raw_bin.startswith(home):
            raw_bin = "$HOME" + raw_bin[len(home):]
        elif raw_bin.startswith("${HOME}"):
            raw_bin = "$HOME" + raw_bin[len("${HOME}"):]

    bin_name = None
    if raw_bin.startswith("$HOME/"):
        rel = raw_bin[len("$HOME/"):]
        if rel in MANAGED_BIN_RELPATHS:
            bin_name = MANAGED_BIN_RELPATHS[rel]
    if not bin_name:
        return None

    action = words[1].strip("\"'\''") if len(words) > 1 else ""
    if action in MANAGED_ACTIONS.get(bin_name, set()):
        return {
            "binary": bin_name,
            "action": action,
            "canonical": action,
            "is_legacy": False
        }
    if action in LEGACY_ACTIONS.get(bin_name, {}):
        return {
            "binary": bin_name,
            "action": action,
            "canonical": LEGACY_ACTIONS[bin_name][action],
            "is_legacy": True
        }
    return None

def derive_mutations(manifest, frag, home):
    mutations = []
    orig_status = manifest.get("original_agterm_status")
    orig_chat = manifest.get("original_mailbox_chat")
    orig = {
        "agterm-status": orig_status if isinstance(orig_status, dict) else {},
        "mailbox-chat": orig_chat if isinstance(orig_chat, dict) else {},
        "safety-guard": manifest.get("original_safety_guard") or {}
    }

    for key, frag_group in frag.items():
        # Older manifests do not own groups introduced by a later installer.
        if "original_" + key.replace("-", "_") not in manifest:
            continue
        if not isinstance(frag_group, dict):
            continue
        orig_group = orig.get(key, {})
        for event_name, hook_list in frag_group.items():
            if not isinstance(hook_list, list):
                continue
            orig_event_list = orig_group.get(event_name, []) if isinstance(orig_group, dict) else []
            for h in hook_list:
                if not isinstance(h, dict):
                    continue
                if "command" in h:
                    h_info = get_managed_hook_info(h["command"])
                    if not h_info:
                        continue
                    found_orig = False
                    for om in orig_event_list:
                        if isinstance(om, dict) and "command" in om:
                            om_info = get_managed_hook_info(om["command"])
                            if om_info and om_info["binary"] == h_info["binary"] and om_info["canonical"] == h_info["canonical"]:
                                if om_info["is_legacy"]:
                                    mutations.append({"type": "upgrade_direct", "key": key, "event": event_name, "from": copy.deepcopy(om), "to": copy.deepcopy(h)})
                                found_orig = True
                                break
                    if not found_orig:
                        mutations.append({"type": "add_direct", "key": key, "event": event_name, "hook": copy.deepcopy(h)})
                elif "matcher" in h and "hooks" in h:
                    pattern = h.get("matcher")
                    matching_orig = [
                        (idx, om) for idx, om in enumerate(orig_event_list)
                        if isinstance(om, dict) and om.get("matcher") == pattern
                    ]
                    if not matching_orig:
                        mutations.append({"type": "add_matcher", "key": key, "event": event_name, "matcher": copy.deepcopy(h)})
                    else:
                        for sub_h in h.get("hooks", []):
                            sub_info = get_managed_hook_info(sub_h.get("command", ""))
                            if not sub_info:
                                continue
                            first_m_idx, first_m = matching_orig[0]
                            first_has = any(
                                isinstance(sh, dict) and (get_managed_hook_info(sh.get("command", "")) or {}).get("canonical") == sub_info["canonical"]
                                for sh in first_m.get("hooks", [])
                            )
                            if not first_has:
                                first_subs = first_m.get("hooks", []) if isinstance(first_m.get("hooks"), list) else []
                                mutations.append({"type": "add_sub", "key": key, "event": event_name, "pattern": pattern, "hook": copy.deepcopy(sub_h), "target_hooks": copy.deepcopy(first_subs)})
    return mutations

# On upgrade, preserve a pre-existing safety guard independently of older groups.
if existing_manifest and "original_safety_guard" not in existing_manifest:
    existing_manifest["original_safety_guard"] = copy.deepcopy(data.get("safety-guard"))
    existing_manifest["created_safety_guard"] = "safety-guard" not in data

if existing_manifest and "mutations" not in existing_manifest:
    existing_manifest["mutations"] = derive_mutations(existing_manifest, frag, home)
    existing_manifest["installed_snapshot"] = copy.deepcopy(data)

def group_has_our_hooks(group, frag_group):
    if not isinstance(group, dict):
        return False
    for event_name, hook_list in frag_group.items():
        if event_name not in group or not isinstance(group[event_name], list):
            return False
        for expected in hook_list:
            if "command" in expected:
                exp_info = get_managed_hook_info(expected["command"])
                if not exp_info:
                    continue
                found = any(
                    isinstance(h, dict) and
                    (get_managed_hook_info(h.get("command", "")) or {}).get("canonical") == exp_info["canonical"] and
                    not (get_managed_hook_info(h.get("command", "")) or {}).get("is_legacy")
                    for h in group[event_name]
                )
                if not found:
                    return False
            elif "matcher" in expected and "hooks" in expected:
                found_matcher = False
                for m in group[event_name]:
                    if isinstance(m, dict) and m.get("matcher") == expected.get("matcher"):
                        for exp_sub in expected["hooks"]:
                            sub_info = get_managed_hook_info(exp_sub.get("command", ""))
                            if not sub_info:
                                continue
                            if not any(
                                isinstance(sh, dict) and
                                (get_managed_hook_info(sh.get("command", "")) or {}).get("canonical") == sub_info["canonical"] and
                                not (get_managed_hook_info(sh.get("command", "")) or {}).get("is_legacy")
                                for sh in m.get("hooks", [])
                            ):
                                return False
                        found_matcher = True
                        break
                if not found_matcher:
                    return False
    return True

already_up_to_date = all(
    group_has_our_hooks(data.get(key), group)
    for key, group in frag.items()
)

if already_up_to_date and os.path.exists(manifest_file):
    tmp_manifest = f"{manifest_file}.tmp.{uuid.uuid4().hex}"
    with open(tmp_manifest, "w", encoding="utf-8") as f:
        json.dump(existing_manifest, f, indent=2)
    os.replace(tmp_manifest, manifest_file)
    sys.exit(0)

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
    "original_safety_guard": existing_manifest.get("original_safety_guard", copy.deepcopy(data.get("safety-guard"))),
    "created_agterm_status": existing_manifest.get("created_agterm_status", "agterm-status" not in data),
    "created_mailbox_chat": existing_manifest.get("created_mailbox_chat", "mailbox-chat" not in data),
    "created_safety_guard": existing_manifest.get("created_safety_guard", "safety-guard" not in data),
    "installed_at": existing_manifest.get("installed_at", int(time.time())),
    "updated_at": int(time.time())
}

mutations = []

# Surgical merge and upgrade reconciliation:
for key, frag_group in frag.items():
    if key not in data or not isinstance(data[key], dict):
        data[key] = {}
    for event_name, hook_list in frag_group.items():
        if event_name not in data[key] or not isinstance(data[key][event_name], list):
            data[key][event_name] = []
        for h in hook_list:
                    if "command" in h:
                        h_info = get_managed_hook_info(h["command"])
                        replaced = False
                        for idx, existing_h in enumerate(data[key][event_name]):
                            if isinstance(existing_h, dict) and "command" in existing_h:
                                ex_info = get_managed_hook_info(existing_h["command"])
                                if ex_info and h_info and ex_info["binary"] == h_info["binary"] and ex_info["canonical"] == h_info["canonical"]:
                                    if ex_info["is_legacy"]:
                                        orig_cmd = copy.deepcopy(existing_h)
                                        data[key][event_name][idx]["command"] = h["command"]
                                        mutations.append({"type": "upgrade_direct", "key": key, "event": event_name, "from": orig_cmd, "to": copy.deepcopy(h)})
                                        replaced = True
                                        break
                                    else:
                                        # Current action already running (preserve user settings/timeout)
                                        replaced = True
                                        break
                        if not replaced:
                            data[key][event_name].append(copy.deepcopy(h))
                            mutations.append({"type": "add_direct", "key": key, "event": event_name, "hook": copy.deepcopy(h)})
                    elif "matcher" in h and "hooks" in h:
                        replaced = False
                        for existing_m in data[key][event_name]:
                            if isinstance(existing_m, dict) and existing_m.get("matcher") == h.get("matcher"):
                                existing_subs = existing_m.setdefault("hooks", [])
                                for sub_h in h["hooks"]:
                                    sub_info = get_managed_hook_info(sub_h.get("command", ""))
                                    sub_replaced = False
                                    for s_idx, s_h in enumerate(existing_subs):
                                        if isinstance(s_h, dict) and "command" in s_h:
                                            ex_sub_info = get_managed_hook_info(s_h["command"])
                                            if ex_sub_info and sub_info and ex_sub_info["binary"] == sub_info["binary"] and ex_sub_info["canonical"] == sub_info["canonical"]:
                                                if ex_sub_info["is_legacy"]:
                                                    orig_sub = copy.deepcopy(s_h)
                                                    existing_subs[s_idx]["command"] = sub_h["command"]
                                                    mutations.append({"type": "upgrade_sub", "key": key, "event": event_name, "pattern": h["matcher"], "from": orig_sub, "to": copy.deepcopy(sub_h)})
                                                    sub_replaced = True
                                                    break
                                                else:
                                                    sub_replaced = True
                                                    break
                                    if not sub_replaced:
                                        target_hooks_snapshot = [copy.deepcopy(sh) for sh in existing_subs]
                                        existing_subs.append(copy.deepcopy(sub_h))
                                        mutations.append({"type": "add_sub", "key": key, "event": event_name, "pattern": h["matcher"], "hook": copy.deepcopy(sub_h), "target_hooks": target_hooks_snapshot})
                                replaced = True
                                break
                        if not replaced:
                            data[key][event_name].append(copy.deepcopy(h))
                            mutations.append({"type": "add_matcher", "key": key, "event": event_name, "matcher": copy.deepcopy(h)})

existing_mutations = existing_manifest.get("mutations", [])
combined_mutations = list(existing_mutations)
for m in mutations:
    if m not in combined_mutations:
        combined_mutations.append(m)

manifest["mutations"] = combined_mutations
manifest["installed_snapshot"] = copy.deepcopy(data)

tmp_manifest = f"{manifest_file}.tmp.{uuid.uuid4().hex}"
with open(tmp_manifest, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
os.replace(tmp_manifest, manifest_file)

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
    # 0. Preflight validation before ANY system changes
    preflight_validation

    if (( UNINSTALL )); then
        log_info "Uninstalling agterm-agent-tools..."
    elif (( DRY_RUN )); then
        log_info "Simulating installation (dry run)..."
    else
        log_info "Installing agterm-agent-tools..."
    fi

    if (( UNINSTALL )); then
        log_info "Managing configurations (preflight check)..."
        manage_agy_hooks_json
        manage_codex_hooks
        manage_agterm_hooks_conf

        log_info "Managing agent skills..."
        make_symlink "$SCRIPT_DIR/skills/agy/mailbox-chat"   "$HOME/.gemini/config/skills/mailbox-chat"
        make_symlink "$SCRIPT_DIR/skills/codex/mailbox-chat" "$HOME/.codex/skills/mailbox-chat"

        log_info "Managing hook scripts..."
        make_symlink "$SCRIPT_DIR/hooks/agy/agy-status-hook.sh"        "$HOME/.config/agterm/hooks/agy/agy-status-hook.sh"
        manage_safety_guard_symlink
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
    manage_safety_guard_symlink
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

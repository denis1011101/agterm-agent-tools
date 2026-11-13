# agterm-agent-tools

A unified toolkit for multi-agent peer collaboration, visual lifecycle indicators, and desktop notifications in [agterm](https://github.com/melonamin/agterm-linux) on Linux.

Integrates **Google Antigravity (`agy`)** and **OpenAI Codex CLI (`codex`)** running side-by-side in agterm split panes, enabling seamless peer discussions, real-time terminal status indicators, and desktop alerts.

---

## Features

### 1. Peer-to-Peer Mailbox Chat (`mailbox-chat.py`)
- **Pane-to-Pane Mailbox Transport**: Facilitates direct agent-to-agent communication between split panes in agterm without simulated keystrokes.
- **Multi-Agent Protocol**: First-class support for `agy` (Antigravity), `codex`, and `claude`.
- **Reactive Wakeups**: Background waiter (`agy-wait`) with immediate resumption upon incoming mail.
- **Safety and Auditability**:
  - Peer messages are treated as advisory input, never as user authorization.
  - Mail receipts are automatically archived under `/tmp/agterm-mailbox-chat-<uid>/`.
  - Non-duplication guards prevent ping-pong loops.

### 2. Visual Agent Status (Traffic Lights)
- **Real-Time Indicators**: Maps agent lifecycle events to agterm pane status indicators:
  - 🔵 **Active (Blinking)**: Agent is executing tools or generating reasoning.
  - 🟡 **Blocked**: Agent is waiting for user confirmation (permission dialogs, questions).
  - 🟢 **Completed**: Agent finished its turn and is idle.
- **Interactive Blocker Detection**: Background pane watcher scans visible terminal screen for interactive prompts (`"Run this command?"`, `"Allow this action?"`, `"Enter to confirm"`).
- **Transcript Turn Analysis**: On task completion, inspects the transcript to ensure turns ending with questions remain flagged as yellow (blocked) until the user replies.

### 3. Desktop Notifications
- **Ubuntu Desktop Banners**: Notifies the user when an agent needs input or confirmation.
- **Delivery Fallback**: Uses `agtermctl notify` when available, gracefully falling back to native `notify-send -a agterm`.
- **Concurrency & Deduplication**: Per-pane file locks (`flock`) prevent racing alerts, with a 3-second deduplication threshold.

### 4. Antigravity Safety Guard (`safety-guard.py`)
- A global `PreToolUse` hook requests confirmation for recognized file deletion, destructive shell redirections, file zeroing, `.ssh` access, SSH transports, and inline script execution.
- Restricted calls return `force_ask`, which agy documents as ignoring cached Always Allow rules. Other calls return `ask` and use agy's permission flow, including existing cached permissions.
- The guard is a heuristic filter. External scripts, configured Git remotes, computed paths, recursive access through parent directories, and unrecognized shell syntax can escape classification. Some unfamiliar commands can also prompt unnecessarily. It does not guarantee approval for every indirect deletion or SSH connection.
- Hook execution alone does not establish enforcement under `--dangerously-skip-permissions`, a failing/timed-out hook, or noninteractive execution. Those engine behaviors require separate integration verification. The installer does not change agent mode or cached allow rules.

### 5. Network Recovery & System Maintenance (`examples/upd_all.sh`)
- **Resilient System Updater**: Updates APT packages, `agy`, `codex`, `opencode`, and `agterm-linux`.
- **Intelligent Connectivity Verification**: Dual ICMP ping and HTTPS 204 connectivity test with 30-second stability check.
- **Hardware-Aware Auto-Recovery**: Reconnects the active physical interface (Ethernet or Wi-Fi) based on the lowest main routing table metric (safely ignoring VPN tables like Tailscale).

---

## Directory Structure

```text
.
├── bin/
│   ├── mailbox-chat.py               # Mailbox CLI and transport daemon
│   └── codex-mailbox                 # Convenience launcher for Codex peer sessions
├── config/
│   ├── agterm-hooks.conf.fragment    # Hook definition for agterm
│   ├── agy-hooks.json.fragment       # Lifecycle hooks for Antigravity (agy)
│   └── codex-hooks.toml.fragment     # Lifecycle hooks for Codex
├── examples/
│   └── upd_all.sh                    # Automated system update & network recovery script
├── hooks/
│   ├── agterm/
│   │   ├── agterm-agent-status.sh    # Base status adapter for agtermctl
│   │   └── agterm-codex-status.sh    # Codex lifecycle hook adapter
│   └── agy/
│       ├── agy-status-hook.sh        # Antigravity lifecycle hook & prompt watcher
│       └── safety-guard.py           # Confirmation filter for destructive/SSH actions
├── skills/
│   ├── agy/mailbox-chat/             # Agent skill for Antigravity
│   └── codex/mailbox-chat/           # Agent skill for Codex
├── tests/
│   ├── test_installer.py             # Unit tests for installer and lifecycle management
│   ├── test_safety_guard.py          # Guard protocol and command/path regression tests
│   ├── test_linux_agy.py             # Unit tests for agy-wait and Linux mailbox transport
│   ├── test_mailbox_chat.py          # Unit tests for mailbox-chat protocol
│   ├── test_network_recovery.sh      # Test suite for NetworkManager recovery logic
│   └── test_notify.sh                # Test suite for concurrency & notification fallback
├── install.sh                        # Automated installer and manager
├── LICENSE                           # MIT License
└── README.md
```

---

## Installation

### Prerequisites
- Linux (Ubuntu 22.04+ recommended)
- `python3` (3.8+)
- `bash` (4.0+)
- [agterm-linux](https://github.com/melonamin/agterm-linux)
- `libnotify-bin` (for desktop fallback notifications via `notify-send`)

### Quick Install

Clone the repository and run `install.sh`:

```bash
git clone https://github.com/denis1011101/agterm-agent-tools.git ~/my/agterm-agent-tools
cd ~/my/agterm-agent-tools
./install.sh
```

The installer links `~/.config/agterm/hooks/agy/safety-guard.py` to the repository and merges the `safety-guard` entry into `~/.gemini/config/hooks.json`. An existing standalone script is backed up beside the link as `safety-guard.py.bak.<timestamp>`. Reinstallation preserves existing hook settings and avoids duplicate entries.

### Dry Run
To inspect changes before modifying any configuration:

```bash
./install.sh --dry-run
```

### Uninstallation
To cleanly remove all symlinks and configurations:

```bash
./install.sh --uninstall
```

> [!NOTE]
> **Data Loss Prevention & Safe Ambiguity Preservation**:
> `install.sh --uninstall` uses transactional manifest tracking and similarity analysis to surgically remove only hooks installed by this toolkit, preserving all user customizations and foreign hooks.
>
> A pre-existing or user-preserved safety-guard registration is retained on uninstall. If it still references the local guard, its symlink is also retained so that the surviving hook keeps working. Backups of standalone scripts are left in place.
>
> If a configuration is detected with ambiguous hook ownership (e.g., identical similarity scores across user-edited matchers) or if more than 6 candidate matchers remain after untouched-entry reduction, the uninstaller stops conservatively with exit code 0 and logs a preservation message. In this scenario, all configuration files, manifest, and symlinks are retained intact to prevent any destructive deletion of user settings.

---

## Usage

### 1. Peer Collaboration in agterm
1. Open `agterm` and split the window (`Ctrl+Shift+D` or via menu).
2. In the **Left Pane**, launch Antigravity:
   ```bash
   agy
   ```
3. In the **Right Pane**, launch Codex with the peer wrapper:
   ```bash
   codex-mailbox
   ```
4. Ask either agent to collaborate:
   > *"Discuss the implementation plan with Codex in the other pane."*

The agents will exchange messages via `mailbox-chat.py say --stdin`, and status indicators in both panes will update dynamically.

### 2. Manual Mailbox Commands

Check current mailbox status and neighboring pane:
```bash
mailbox-chat.py status
```

Send a peer message manually:
```bash
mailbox-chat.py say --stdin <<'EOF'
Please review the latest commit on branch master.
EOF
```

Run background receiver:
```bash
mailbox-chat.py agy-wait
```

---

## Running Tests

All components include automated test coverage:

```bash
# 1. Run Python unit tests (protocol, Linux transport, installer, safety guard)
python3 -m unittest discover -s tests -p "test_*.py"

# 2. Run Desktop notification test suite (against production agy-status-hook.sh)
bash tests/test_notify.sh

# 3. Run Network recovery test suite (against production examples/upd_all.sh)
bash tests/test_network_recovery.sh
```

Safety-guard tests feed synthetic tool-call JSON to the script; they never execute the shell commands under inspection or read real SSH keys. Installer tests use temporary home directories.

Continuous integration runs automatically on GitHub Actions (`.github/workflows/ci.yml`) on every push and pull request across Python 3.10–3.13, running ShellCheck and the complete test suites.

---

## Contributing & Development Rules
- **No Hardcoded Paths**: Always use `$HOME`, `~`, or dynamic user ID (`${UID:-$(id -u)}`).
- **Never Commit Secrets**: Do not track `.env`, auth files, SQLite databases, or `/tmp` receipts.
- **Maintain Compatibility**: Hooks must execute cleanly without breaking existing agent CLI behavior.

---

## License

This project is licensed under the [MIT License](LICENSE).

#!/usr/bin/env python3
"""Unit tests for install.sh installer and lifecycle management."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

REPO_ROOT = Path(__file__).resolve().parent.parent


class TestInstaller(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp(prefix="test-installer-")
        self.root = Path(self.temp_dir)
        self.mock_bin = self.root / "mock_bin"
        self.mock_bin.mkdir(parents=True)
        (self.mock_bin / "agtermctl").write_text("#!/bin/sh\nexit 0\n")
        (self.mock_bin / "agtermctl").chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def run_installer(self, home_dir: Path, args=(), expect_fail=False):
        env = os.environ.copy()
        env["HOME"] = str(home_dir)
        env["PATH"] = f"{self.mock_bin}:{env.get('PATH', '')}"
        cmd = ["bash", str(REPO_ROOT / "install.sh")] + list(args)
        r = subprocess.run(
            cmd,
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
        )
        if expect_fail:
            self.assertNotEqual(r.returncode, 0, f"Expected failure, but succeeded: {r.stdout}")
        else:
            self.assertEqual(r.returncode, 0, f"Installer failed with code {r.returncode}: {r.stderr}")
        return r

    def test_clean_install_and_symlinks(self):
        home = self.root / "home_clean"
        (home / ".codex").mkdir(parents=True)
        self.run_installer(home)

        # Binaries
        self.assertTrue((home / ".local/bin/mailbox-chat.py").is_symlink())
        self.assertTrue((home / ".local/bin/codex-mailbox").is_symlink())

        # Hooks
        self.assertTrue((home / ".config/agterm/hooks/agy/agy-status-hook.sh").is_symlink())
        self.assertTrue((home / ".config/agterm/agent-status/agterm-agent-status.sh").is_symlink())
        self.assertTrue((home / ".config/agterm/agent-status/agterm-codex-status.sh").is_symlink())

        # Skills
        self.assertTrue((home / ".gemini/config/skills/mailbox-chat").is_symlink())
        self.assertTrue((home / ".codex/skills/mailbox-chat").is_symlink())

        # Configs
        agy_json = home / ".gemini/config/hooks.json"
        self.assertTrue(agy_json.is_file())
        with open(agy_json, "r", encoding="utf-8") as f:
            data = json.load(f)
        self.assertIn("agterm-status", data)
        self.assertIn("mailbox-chat", data)

        hooks_conf = home / ".config/agterm/hooks.conf"
        self.assertTrue(hooks_conf.is_file())
        self.assertIn("mailbox-chat.py", hooks_conf.read_text())

        if tomllib:
            codex_conf = home / ".codex/config.toml"
            self.assertTrue(codex_conf.is_file())
            codex_data = tomllib.loads(codex_conf.read_text())
            session_start_commands = [
                h["command"] for hook in codex_data["hooks"]["SessionStart"] for h in hook["hooks"]
            ]
            self.assertTrue(any("mailbox-chat.py" in cmd and "codex-hook" in cmd for cmd in session_start_commands))
            self.assertTrue(any("agterm-codex-status.sh" in cmd for cmd in session_start_commands))

    def test_reinstall_idempotency(self):
        home = self.root / "home_reinstall"
        (home / ".codex").mkdir(parents=True)
        self.run_installer(home)
        self.run_installer(home)

        hooks_conf = home / ".config/agterm/hooks.conf"
        matches = [l for l in hooks_conf.read_text().splitlines() if "mailbox-chat" in l]
        self.assertEqual(len(matches), 1, "Duplicate hook line added on reinstall")

    def test_malformed_json_aborts_without_overwriting(self):
        home = self.root / "home_malformed"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        corrupted_content = "{broken json, do not overwrite"
        agy_json.write_text(corrupted_content)

        self.run_installer(home, expect_fail=True)
        self.assertEqual(agy_json.read_text(), corrupted_content)

    def test_uninstall_preserves_unowned_keys(self):
        home = self.root / "home_unowned"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        custom_data = {
            "agterm-status": {"user_custom": True},
            "mailbox-chat": {"user_custom": True},
            "other_hook": {"keep_me": 123},
        }
        agy_json.write_text(json.dumps(custom_data))

        self.run_installer(home, args=["--uninstall"])
        with open(agy_json, "r", encoding="utf-8") as f:
            remaining = json.load(f)
        self.assertIn("agterm-status", remaining)
        self.assertIn("mailbox-chat", remaining)
        self.assertIn("other_hook", remaining)

    def test_symlink_replacement_does_not_write_through_foreign_dir(self):
        home = self.root / "home_foreign"
        dest = home / ".codex/skills/mailbox-chat"
        dest.parent.mkdir(parents=True)
        foreign_target = self.root / "foreign_skill_dir"
        foreign_target.mkdir(parents=True)
        dest.symlink_to(foreign_target, target_is_directory=True)

        self.run_installer(home)
        self.assertEqual(dest.resolve(), (REPO_ROOT / "skills/codex/mailbox-chat").resolve())
        self.assertEqual(list(foreign_target.iterdir()), [], "Foreign directory modified by write-through!")

    def test_uninstall_without_install_preserves_custom_hooks_identically(self):
        home = self.root / "home_custom_hooks"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        custom_data = {
            "mailbox-chat": {
                "PreInvocation": [
                    {"command": "/custom/mailbox-chat.py custom-mode"},
                    {"command": "echo KEEP_ME"}
                ]
            },
            "agterm-status": {
                "custom_command": "/custom/agy-status-hook.sh special-mode"
            },
            "other": {"keep": True}
        }
        agy_json.write_text(json.dumps(custom_data))

        # Uninstall without prior install must not touch hooks.json
        self.run_installer(home, args=["--uninstall"])
        with open(agy_json, "r", encoding="utf-8") as f:
            content = json.load(f)
        self.assertEqual(content, custom_data)

    def test_backup_preservation_and_restore_after_install(self):
        home = self.root / "home_backup_restore"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        custom_data = {
            "mailbox-chat": {"custom": 1},
            "agterm-status": {"custom": 2},
            "other": {"keep": True}
        }
        agy_json.write_text(json.dumps(custom_data))

        # First install creates backup and applies fragment
        self.run_installer(home)
        backups = list(agy_json.parent.glob("hooks.json.bak.*"))
        self.assertEqual(len(backups), 1)
        with open(backups[0], "r", encoding="utf-8") as f:
            self.assertEqual(json.load(f), custom_data)

        # Second install is idempotent, does not overwrite backup
        self.run_installer(home)
        backups_after = list(agy_json.parent.glob("hooks.json.bak.*"))
        self.assertEqual(len(backups_after), 1)

        # Uninstall restores original custom config
        self.run_installer(home, args=["--uninstall"])
        with open(agy_json, "r", encoding="utf-8") as f:
            restored = json.load(f)
        self.assertEqual(restored, custom_data)

    def test_post_install_user_edit_preserved_on_uninstall(self):
        home = self.root / "home_post_edit"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        custom_data = {
            "mailbox-chat": {"custom": "ORIGINAL"},
            "agterm-status": {"custom": "ORIGINAL"},
            "other": {"keep": True}
        }
        agy_json.write_text(json.dumps(custom_data))

        self.run_installer(home)
        current = json.loads(agy_json.read_text())
        current["mailbox-chat"]["my-added-hook"] = {"command": "echo KEEP_ME"}
        agy_json.write_text(json.dumps(current))

        self.run_installer(home, args=["--uninstall"])
        res = json.loads(agy_json.read_text())
        self.assertIn("my-added-hook", res["mailbox-chat"])
        self.assertEqual(res["mailbox-chat"].get("custom"), "ORIGINAL")
        self.assertEqual(res["agterm-status"].get("custom"), "ORIGINAL")

    def test_reinstall_preserves_original_manifest_and_restores_original(self):
        home = self.root / "home_reinstall_manifest"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        orig_data = {
            "mailbox-chat": {"custom": "ORIGINAL"},
            "agterm-status": {"custom": "ORIGINAL"},
            "other": {"keep": True}
        }
        agy_json.write_text(json.dumps(orig_data))

        self.run_installer(home)
        manifest_file = home / ".local/state/agterm-agent-tools/manifest.json"
        before = json.loads(manifest_file.read_text())

        # User adds extra hook
        current = json.loads(agy_json.read_text())
        current["mailbox-chat"]["my-added-hook"] = {"command": "echo KEEP_ME"}
        agy_json.write_text(json.dumps(current))

        # Reinstall
        self.run_installer(home)
        after = json.loads(manifest_file.read_text())
        self.assertEqual(before["original_mailbox_chat"], after["original_mailbox_chat"])

        # Clean user extra hook and uninstall
        current = json.loads(agy_json.read_text())
        del current["mailbox-chat"]["my-added-hook"]
        agy_json.write_text(json.dumps(current))

        self.run_installer(home, args=["--uninstall"])
        restored = json.loads(agy_json.read_text())
        self.assertEqual(restored["mailbox-chat"], orig_data["mailbox-chat"])
        self.assertEqual(restored["agterm-status"], orig_data["agterm-status"])

    def test_corrupt_manifest_aborts_without_modifying_config(self):
        home = self.root / "home_corrupt_manifest"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        custom_data = {"mailbox-chat": {"keep": True}}
        agy_json.write_text(json.dumps(custom_data))

        self.run_installer(home)
        before_content = agy_json.read_text()
        manifest_file = home / ".local/state/agterm-agent-tools/manifest.json"
        manifest_file.write_text("{broken")

        self.run_installer(home, args=["--uninstall"], expect_fail=True)
        self.assertEqual(agy_json.read_text(), before_content)
        self.assertTrue(manifest_file.exists())

    def test_nested_custom_command_in_matcher_preserved_on_uninstall(self):
        home = self.root / "home_nested_custom"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["agterm-status"]["PreToolUse"][0]["hooks"].append({"type": "command", "command": "echo KEEP_ME"})
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        self.assertIn("KEEP_ME", agy_json.read_text())

    def test_foreign_basename_hook_restored_identically_on_uninstall(self):
        home = self.root / "home_foreign_basename"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        original = {"mailbox-chat": {"PreInvocation": [{"type": "command", "command": "/custom/mailbox-chat.py custom-mode"}]}}
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        self.run_installer(home, args=["--uninstall"])
        self.assertEqual(json.loads(agy_json.read_text()), original)

    def test_corrupt_manifest_on_reinstall_aborts_and_preserves_manifest(self):
        home = self.root / "home_corrupt_reinstall"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        original = {"mailbox-chat": {"custom": "ORIGINAL"}, "agterm-status": {"custom": "ORIGINAL"}}
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        manifest_file = home / ".local/state/agterm-agent-tools/manifest.json"
        manifest_file.write_text("{broken")

        data = json.loads(agy_json.read_text())
        del data["agterm-status"]["Stop"]
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, expect_fail=True)
        self.assertEqual(manifest_file.read_text(), "{broken")

    def test_upgrade_reconciles_managed_hook_in_place_without_duplicates(self):
        home = self.root / "home_upgrade_reconcile"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["agterm-status"]["Stop"][0]["command"] = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" old-stop"
        agy_json.write_text(json.dumps(data))

        self.run_installer(home)
        stop_hooks = json.loads(agy_json.read_text())["agterm-status"]["Stop"]
        expected_stop = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" stop"
        self.assertEqual(len(stop_hooks), 1)
        self.assertEqual(stop_hooks[0]["command"], expected_stop)

    def test_foreign_same_action_hook_preserved_and_restored(self):
        home = self.root / "home_foreign_same_action"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        original = {
            "mailbox-chat": {
                "PreInvocation": [
                    {"type": "command", "command": "/custom/mailbox-chat.py agy-hook", "timeout": 40}
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        cmds = [h["command"] for h in data["mailbox-chat"]["PreInvocation"]]
        self.assertIn("/custom/mailbox-chat.py agy-hook", cmds)
        self.assertIn("\"$HOME/.local/bin/mailbox-chat.py\" agy-hook", cmds)

        self.run_installer(home, args=["--uninstall"])
        restored = json.loads(agy_json.read_text())
        self.assertEqual(restored, original)

    def test_custom_timeout_on_managed_hook_preserved(self):
        home = self.root / "home_custom_timeout"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["agterm-status"]["Stop"][0]["timeout"] = 40
        agy_json.write_text(json.dumps(data))

        self.run_installer(home)
        reinstalled = json.loads(agy_json.read_text())
        self.assertEqual(reinstalled["agterm-status"]["Stop"][0].get("timeout"), 40)

    def test_preflight_validation_aborts_before_symlinks(self):
        home = self.root / "home_preflight_abort"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        agy_json.write_text("{malformed_json: true,")

        self.run_installer(home, expect_fail=True)
        # Verify no symlinks or directories were created in .local/bin
        bin_target = home / ".local/bin/mailbox-chat.py"
        self.assertFalse(bin_target.exists())
        self.assertFalse((home / ".local/state/agterm-agent-tools/manifest.json").exists())

    def test_user_edited_command_preserved_on_uninstall_without_stale_command(self):
        home = self.root / "home_edit_original"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        original = {"mailbox-chat": {"PreInvocation": [{"type": "command", "command": "echo ORIGINAL"}]}}
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["mailbox-chat"]["PreInvocation"][0]["command"] = "echo UPDATED"
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        expected = {"mailbox-chat": {"PreInvocation": [{"type": "command", "command": "echo UPDATED"}]}}
        self.assertEqual(json.loads(agy_json.read_text()), expected)

    def test_user_deleted_command_stays_deleted_on_uninstall(self):
        home = self.root / "home_delete_original"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        original = {"mailbox-chat": {"PreInvocation": [{"type": "command", "command": "echo ORIGINAL"}]}}
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        del data["mailbox-chat"]["PreInvocation"][0]
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        self.assertNotIn("ORIGINAL", agy_json.read_text())

    def test_custom_action_on_managed_binary_preserved_on_uninstall(self):
        home = self.root / "home_custom_action_after"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        custom = {"type": "command", "command": "\"$HOME/.local/bin/mailbox-chat.py\" status"}
        data["mailbox-chat"]["PreInvocation"].append(custom)
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        self.assertIn(" status", agy_json.read_text())
        self.assertNotIn("agy-hook", agy_json.read_text())

    def test_custom_action_on_managed_binary_preserved_during_install(self):
        home = self.root / "home_custom_action_before"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        custom = {"type": "command", "command": "\"$HOME/.local/bin/mailbox-chat.py\" status"}
        original = {"mailbox-chat": {"PreInvocation": [custom]}}
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        installed = json.loads(agy_json.read_text())["mailbox-chat"]["PreInvocation"]
        self.assertIn(custom, installed)
        managed = {"type": "command", "command": "\"$HOME/.local/bin/mailbox-chat.py\" agy-hook", "timeout": 5}
        self.assertIn(managed, installed)

    def test_multiple_direct_hooks_multiplicity_preserved_on_uninstall(self):
        home = self.root / "home_multi_direct"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        stop_cmd = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" stop"
        original = {
            "agterm-status": {
                "Stop": [
                    {"type": "command", "command": stop_cmd, "timeout": 40},
                    {"type": "command", "command": stop_cmd, "timeout": 60},
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        self.run_installer(home, args=["--uninstall"])
        self.assertEqual(json.loads(agy_json.read_text()), original)

    def test_multiple_matchers_with_same_pattern_preserved_on_uninstall(self):
        home = self.root / "home_multi_matchers"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        pattern = "ask_question|ask_permission"
        ask_cmd = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" ask"
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo CUSTOM"}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 40}]},
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        self.run_installer(home, args=["--uninstall"])
        self.assertEqual(json.loads(agy_json.read_text()), original)

    def test_multiple_matchers_reorder_and_user_edit_preserved_on_uninstall(self):
        home = self.root / "home_reorder_edit_matchers"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        pattern = "ask_question|ask_permission"
        ask_cmd = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" ask"
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo CUSTOM"}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 40}]},
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        matchers = data["agterm-status"]["PreToolUse"]
        matchers.reverse()
        matchers[0]["hooks"][0]["timeout"] = 50
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        expected = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 50}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo CUSTOM"}]},
                ]
            }
        }
        self.assertEqual(result, expected)

    def test_multiple_matchers_edit_custom_command_only_preserved_on_uninstall(self):
        home = self.root / "home_multi_matchers_edit_custom_only"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        pattern = "ask_question|ask_permission"
        ask_cmd = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" ask"
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo ORIGINAL"}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 40}]},
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["agterm-status"]["PreToolUse"][0]["hooks"][0]["command"] = "echo UPDATED"
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        expected = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo UPDATED"}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 40}]},
                ]
            }
        }
        self.assertEqual(result, expected)

    def test_multiple_matchers_edit_custom_command_and_timeout_preserved_on_uninstall(self):
        home = self.root / "home_multi_matchers_edit_custom_and_timeout"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        pattern = "ask_question|ask_permission"
        ask_cmd = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" ask"
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo ORIGINAL"}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 40}]},
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["agterm-status"]["PreToolUse"][0]["hooks"][0]["command"] = "echo UPDATED"
        data["agterm-status"]["PreToolUse"][1]["hooks"][0]["timeout"] = 50
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        expected = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo UPDATED"}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 50}]},
                ]
            }
        }
        self.assertEqual(result, expected)

    def test_user_deleted_installer_child_leaves_original_matcher_intact_on_uninstall(self):
        home = self.root / "home_deleted_installer_child"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        pattern = "ask_question|ask_permission"
        ask_cmd = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" ask"
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo CUSTOM"}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 40}]},
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        del data["agterm-status"]["PreToolUse"][0]["hooks"][1]
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        self.assertEqual(result, original)

    def test_reinstall_mutation_recorded_and_removed_on_uninstall(self):
        home = self.root / "home_reinstall_mutation"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        stop_cmd = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" stop"
        original = {"agterm-status": {"Stop": [{"type": "command", "command": stop_cmd, "timeout": 40}]}}
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        manifest_file = home / ".local/state/agterm-agent-tools/manifest.json"
        before = json.loads(manifest_file.read_text())["mutations"]

        data = json.loads(agy_json.read_text())
        del data["agterm-status"]["Stop"]
        agy_json.write_text(json.dumps(data))

        self.run_installer(home)
        after = json.loads(manifest_file.read_text())["mutations"]
        self.assertTrue(any(m.get("event") == "Stop" for m in after))
        self.assertNotEqual(before, after)

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        self.assertFalse(result.get("agterm-status", {}).get("Stop"))

    def test_legacy_manifest_migration_and_provenance_preservation(self):
        home = self.root / "home_legacy_manifest_migration"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        pattern = "ask_question|ask_permission"
        ask_cmd = "\"$HOME/.config/agterm/hooks/agy/agy-status-hook.sh\" ask"
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": pattern, "hooks": [{"type": "command", "command": "echo ORIGINAL"}]},
                    {"matcher": pattern, "hooks": [{"type": "command", "command": ask_cmd, "timeout": 40}]},
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        manifest_file = home / ".local/state/agterm-agent-tools/manifest.json"
        legacy = json.loads(manifest_file.read_text())
        legacy.pop("mutations", None)
        legacy.pop("installed_snapshot", None)
        manifest_file.write_text(json.dumps(legacy))

        data = json.loads(agy_json.read_text())
        data["agterm-status"]["PreToolUse"][0]["hooks"][0]["command"] = "echo UPDATED"
        agy_json.write_text(json.dumps(data))

        self.run_installer(home)
        self.assertIn("mutations", json.loads(manifest_file.read_text()))

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        has_ask40 = any(
            sh.get("timeout") == 40
            for m in result.get("agterm-status", {}).get("PreToolUse", [])
            for sh in m.get("hooks", [])
        )
        self.assertTrue(has_ask40)

    def test_same_default_timeout_reordered_matcher_protected_on_uninstall(self):
        home = self.root / "home_same_timeout_reorder"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        frag = json.loads((REPO_ROOT / "config/agy-hooks.json.fragment").read_text())
        matcher = frag["agterm-status"]["PreToolUse"][0]
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": matcher["matcher"], "hooks": [{"type": "command", "command": "echo CUSTOM"}]},
                    copy.deepcopy(matcher),
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["agterm-status"]["PreToolUse"].reverse()
        agy_json.write_text(json.dumps(data))

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        expected = copy.deepcopy(original)
        expected["agterm-status"]["PreToolUse"].reverse()
        self.assertEqual(result, expected)

    def test_legacy_manifest_repair_merges_and_uninstalls_all(self):
        home = self.root / "home_legacy_repair_all"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        agy_json.write_text(json.dumps({}))

        self.run_installer(home)
        manifest_file = home / ".local/state/agterm-agent-tools/manifest.json"
        legacy = json.loads(manifest_file.read_text())
        legacy.pop("mutations", None)
        legacy.pop("installed_snapshot", None)
        manifest_file.write_text(json.dumps(legacy))

        data = json.loads(agy_json.read_text())
        del data["agterm-status"]["Stop"]
        agy_json.write_text(json.dumps(data))

        self.run_installer(home)
        journal = json.loads(manifest_file.read_text()).get("mutations", [])
        events = [(m["key"], m["event"]) for m in journal]
        self.assertIn(("agterm-status", "Stop"), events)
        self.assertIn(("agterm-status", "PreToolUse"), events)

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        self.assertEqual(result, {})

    def test_user_extended_matcher_child_preserved_on_uninstall(self):
        home = self.root / "home_user_extended_matcher"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        frag = json.loads((REPO_ROOT / "config/agy-hooks.json.fragment").read_text())
        matcher = frag["agterm-status"]["PreToolUse"][0]
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": matcher["matcher"], "hooks": [{"type": "command", "command": "echo CUSTOM"}]},
                    copy.deepcopy(matcher),
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["agterm-status"]["PreToolUse"].reverse()
        custom = {"type": "command", "command": "echo KEEP_ME"}
        data["agterm-status"]["PreToolUse"][0]["hooks"].append(custom)
        agy_json.write_text(json.dumps(data))

        expected = copy.deepcopy(original)
        expected["agterm-status"]["PreToolUse"].reverse()
        expected["agterm-status"]["PreToolUse"][0]["hooks"].append(custom)

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        self.assertEqual(result, expected)

    def test_combined_custom_edits_preserve_original_ask(self):
        home = self.root / "home_combined_custom_edits"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        frag = json.loads((REPO_ROOT / "config/agy-hooks.json.fragment").read_text())
        matcher = frag["agterm-status"]["PreToolUse"][0]
        original = {
            "agterm-status": {
                "PreToolUse": [
                    {"matcher": matcher["matcher"], "hooks": [{"type": "command", "command": "echo CUSTOM"}]},
                    copy.deepcopy(matcher),
                ]
            }
        }
        agy_json.write_text(json.dumps(original))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        data["agterm-status"]["PreToolUse"][0]["hooks"][0]["command"] = "echo UPDATED"
        data["agterm-status"]["PreToolUse"].reverse()
        custom = {"type": "command", "command": "echo KEEP_ME"}
        data["agterm-status"]["PreToolUse"][0]["hooks"].append(custom)
        agy_json.write_text(json.dumps(data))

        expected = copy.deepcopy(original)
        expected["agterm-status"]["PreToolUse"][0]["hooks"][0]["command"] = "echo UPDATED"
        expected["agterm-status"]["PreToolUse"].reverse()
        expected["agterm-status"]["PreToolUse"][0]["hooks"].append(custom)

        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        self.assertEqual(result, expected)

    def test_add_matcher_rolls_back_installed_matcher_after_user_prepend(self):
        home = self.root / "home_prepend_user_matcher"
        agy_json = home / ".gemini/config/hooks.json"
        agy_json.parent.mkdir(parents=True)
        frag = json.loads((REPO_ROOT / "config/agy-hooks.json.fragment").read_text())
        matcher = frag["agterm-status"]["PreToolUse"][0]
        agy_json.write_text(json.dumps({}))

        self.run_installer(home)
        data = json.loads(agy_json.read_text())
        custom = {"type": "command", "command": "echo KEEP_ME"}
        user_matcher = {"matcher": matcher["matcher"], "hooks": [custom]}
        data["agterm-status"]["PreToolUse"].insert(0, user_matcher)
        agy_json.write_text(json.dumps(data))

        expected = {"agterm-status": {"PreToolUse": [user_matcher]}}
        self.run_installer(home, args=["--uninstall"])
        result = json.loads(agy_json.read_text())
        self.assertEqual(result, expected)

    def test_matrix_rename_reorder_append_remove_combinations(self):
        frag = json.loads((REPO_ROOT / "config/agy-hooks.json.fragment").read_text())
        matcher = frag["agterm-status"]["PreToolUse"][0]

        # Combinations: (rename_custom, reorder_matchers, append_custom, remove_installer_hook)
        cases = [
            (True, False, False, False),  # rename only
            (True, True, False, False),   # rename + reorder
            (True, False, True, False),   # rename + append
            (True, True, True, False),    # rename + reorder + append
            (False, True, False, True),   # reorder + remove
            (True, True, True, True),     # rename + reorder + append + remove
        ]

        for idx, (do_rename, do_reorder, do_append, do_remove) in enumerate(cases):
            case_name = f"matrix_{idx}_ren{int(do_rename)}_reo{int(do_reorder)}_app{int(do_append)}_rem{int(do_remove)}"
            home = self.root / case_name
            agy_json = home / ".gemini/config/hooks.json"
            agy_json.parent.mkdir(parents=True)
            original = {
                "agterm-status": {
                    "PreToolUse": [
                        {"matcher": matcher["matcher"], "hooks": [{"type": "command", "command": "echo CUSTOM"}]},
                        copy.deepcopy(matcher),
                    ]
                }
            }
            agy_json.write_text(json.dumps(original))

            self.run_installer(home)
            data = json.loads(agy_json.read_text())

            # Mutations after install
            if do_rename:
                data["agterm-status"]["PreToolUse"][0]["hooks"][0]["command"] = "echo UPDATED"
            if do_remove:
                # Remove the installer-added hook from matcher 0
                data["agterm-status"]["PreToolUse"][0]["hooks"] = [
                    h for h in data["agterm-status"]["PreToolUse"][0]["hooks"]
                    if not (isinstance(h, dict) and "agy-status-hook.sh" in h.get("command", ""))
                ]
            if do_reorder:
                data["agterm-status"]["PreToolUse"].reverse()
            if do_append:
                target_idx = 0 if do_reorder else 1
                data["agterm-status"]["PreToolUse"][target_idx]["hooks"].append({"type": "command", "command": "echo EXTRA"})

            agy_json.write_text(json.dumps(data))

            # Calculate expected
            expected = copy.deepcopy(original)
            if do_rename:
                expected["agterm-status"]["PreToolUse"][0]["hooks"][0]["command"] = "echo UPDATED"
            if do_reorder:
                expected["agterm-status"]["PreToolUse"].reverse()
            if do_append:
                target_idx = 0 if do_reorder else 1
                expected["agterm-status"]["PreToolUse"][target_idx]["hooks"].append({"type": "command", "command": "echo EXTRA"})

            self.run_installer(home, args=["--uninstall"])
            result = json.loads(agy_json.read_text())
            self.assertEqual(result, expected, f"Failed case {case_name}")


if __name__ == "__main__":
    unittest.main()

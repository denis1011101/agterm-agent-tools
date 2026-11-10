#!/usr/bin/env python3
"""Unit tests for install.sh installer and lifecycle management."""

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


if __name__ == "__main__":
    unittest.main()

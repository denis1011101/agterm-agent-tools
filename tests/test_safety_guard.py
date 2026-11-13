#!/usr/bin/env python3
"""Exercise the hook JSON protocol without executing any supplied shell command."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GUARD = Path(__file__).resolve().parent.parent / "hooks/agy/safety-guard.py"


class TestSafetyGuard(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-safety-guard-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ.copy()
        self.env["HOME"] = str(self.root)
        (self.root / "victim").write_text("existing content\n")
        (self.root / "with space").write_text("existing content\n")
        (self.root / ".ssh").mkdir()
        (self.root / ".ssh/config").write_text("# synthetic fixture, no credentials\n")
        (self.root / "keys-link").symlink_to(self.root / ".ssh", target_is_directory=True)

    def invoke(self, payload=None, raw=None):
        if raw is None:
            raw = json.dumps(payload)
        result = subprocess.run(
            [sys.executable, str(GUARD)], input=raw, text=True,
            capture_output=True, timeout=5, env=self.env, cwd=self.root,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        data = json.loads(result.stdout)
        self.assertIn(data.get("decision"), ("ask", "force_ask"))
        if data["decision"] == "force_ask":
            self.assertTrue(data.get("reason"))
        return data["decision"]

    def tool(self, name, args, cwd=None):
        return self.invoke({
            "cwd": str(self.root if cwd is None else cwd),
            "toolCall": {"name": name, "args": args},
        })

    def command(self, command):
        return self.tool("run_command", {"CommandLine": command})

    def test_deletion_and_overwrite_commands_require_confirmation(self):
        commands = [
            "rm victim", "unlink victim", "shred victim", "rmdir empty",
            "git rm victim", "git clean -fd", "git reset --hard",
            "git -C /tmp rm victim", "git -c color.ui=never clean -fd",
            "find . -delete", r"find . -exec /bin/rm {} \;",
            r'find . -exec sh -c "rm victim" \;',
            "truncate -s 0 victim", "cp /dev/null victim",
            "dd if=/dev/null of=victim", 'printf "" | tee victim',
            "rsync --delete src/ dst/", "rsync --del src/ dst/",
            "rsync --delete-before src/ dst/", "rsync --delete-after src/ dst/",
            "rsync --delete-during src/ dst/", "rsync --delete-delay src/ dst/",
            "rsync --delete-excluded src/ dst/",
            "rsync --delete-missing-args src/ dst/",
            "rsync --remove-source-files src/ dst/",
            "echo data>victim", ': >"with space"', ": >|victim",
            "echo hi >victim >other", 'OUT=victim; : >"$OUT"',
            "cd subdir; : >nested-victim",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.command(command), "force_ask")

    def test_shell_syntax_and_wrappers_do_not_hide_restricted_actions(self):
        commands = [
            "echo ok;rm victim", "echo ok\nrm victim", "echo ok && rm victim",
            "echo ok || rm victim", "true & rm victim", '(rm victim)',
            "{ rm victim; }", "! rm victim", "if true; then rm victim; fi",
            'for f in victim; do rm "$f"; done',
            'echo "$(rm victim)"', 'echo "$(echo ok; rm victim)"',
            'echo "`rm victim`"', "FLAG=1 rm victim", "command rm victim",
            "env FLAG=1 ssh example.invalid", "sudo FLAG=1 ssh example.invalid",
            "/usr/bin/timeout 5 ssh example.invalid", "timeout 0.5 ssh example.invalid",
            "nice -n 5 ssh example.invalid", "strace -o trace.out ssh example.invalid",
            "xargs -I {} rm {}", 'bash -lc "rm victim"',
            'bash -c "echo ok; rm victim"', "2>/dev/null rm victim",
            "2> /dev/null rm victim", "< /dev/null rm victim",
            "2> /dev/null ssh example.invalid",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.command(command), "force_ask")

    def test_ssh_transports_require_confirmation(self):
        commands = [
            "ssh example.invalid", "scp victim example.invalid:/tmp/victim",
            "sftp example.invalid", "rsync localhost:/tmp/file /tmp/dest",
            "rsync -e ssh src/ example.invalid:/tmp/dest",
            "git clone git@example.invalid:repo.git",
            "git clone ssh://example.invalid/repo.git",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.command(command), "force_ask")

    def test_inline_execution_requires_confirmation(self):
        commands = [
            "python3 -c 'import os; os.unlink(\"victim\")'",
            "python3.12 -c 'print(1)'", "ruby -e'puts 1'",
            "node -e 'console.log(1)'", "perl -e 'print 1'",
            'eval "ssh example.invalid"', "exec ssh example.invalid",
            'git -c alias.zap="!rm victim" zap',
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.command(command), "force_ask")

    def test_ssh_paths_cwd_symlinks_and_nested_arguments(self):
        for path in ("~/.ssh/config", "$HOME/.ssh/config", ".ssh/config", "keys-link/config"):
            with self.subTest(path=path):
                self.assertEqual(self.tool("view_file", {"AbsolutePath": path}), "force_ask")
                self.assertEqual(self.command("cat " + path), "force_ask")
        self.assertEqual(self.tool("run_command", {"CommandLine": "ls"}, self.root / ".ssh"), "force_ask")
        self.assertEqual(self.tool("example_tool", {"Paths": [str(self.root / ".ssh/config")]}), "force_ask")
        self.assertEqual(self.tool("example_tool", {"request": {"Path": "~/.ssh/config"}}), "force_ask")
        self.assertEqual(self.command('cat "$HOME"/.*/*'), "force_ask")

    def test_write_file_zeroing_existing_content(self):
        for path_key, content_key in (("Path", "Content"), ("TargetFile", "CodeContent")):
            for content in ("", " \n"):
                with self.subTest(path_key=path_key, content=content):
                    self.assertEqual(self.tool("write_file", {path_key: str(self.root / "victim"), content_key: content}), "force_ask")
        self.assertEqual((self.root / "victim").read_text(), "existing content\n")

    def test_ordinary_commands_and_quoted_data_keep_standard_permissions(self):
        commands = [
            "ls", "cat victim", "cat config/database.yml", "git status --short",
            "printf '%s\\n' 'then'", "echo '$(rm victim)'",
            "printf '%s\\n' '>victim'", "echo hello >/dev/null",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.command(command), "ask")

    def test_empty_new_file_and_partial_edit_keep_standard_permissions(self):
        self.assertEqual(self.tool("write_file", {"TargetFile": str(self.root / "new-file"), "CodeContent": ""}), "ask")
        self.assertEqual(self.tool("replace_file_content", {
            "TargetFile": str(self.root / "victim"),
            "TargetContent": "existing", "ReplacementContent": "",
        }), "ask")

    def test_invalid_payloads_require_confirmation(self):
        for raw in ("", "{invalid", "[]", "null", "{}"):
            with self.subTest(raw=raw):
                self.assertEqual(self.invoke(raw=raw), "force_ask")
        payloads = [
            {"toolCall": {"args": {}}},
            {"toolCall": {"name": "run_command", "args": {}}},
            {"toolCall": {"name": "run_command", "args": None}},
            {"toolCall": {"name": "run_command", "args": {"CommandLine": 42}}},
            {"toolCall": {"name": "view_file", "args": []}},
        ]
        for payload in payloads:
            with self.subTest(payload=payload):
                self.assertEqual(self.invoke(payload), "force_ask")
        self.assertEqual(self.command("echo 'unterminated"), "force_ask")

    def test_restricted_payloads_are_never_executed(self):
        marker = self.root / "must-not-exist"
        self.assertEqual(self.command("touch " + str(marker) + "; rm victim"), "force_ask")
        self.assertFalse(marker.exists())
        self.assertEqual((self.root / "victim").read_text(), "existing content\n")


if __name__ == "__main__":
    unittest.main()

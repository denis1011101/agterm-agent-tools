#!/usr/bin/env python3
"""Antigravity CLI (agy) Safety Guard Hook (v4).

Enforces confirmation (force_ask) for:
1. File deletion:
   - CLI commands: rm, unlink, shred, rmdir, git rm, git clean, git reset --hard,
     find -delete, find -exec rm, truncate, rsync --delete/--remove-source-files
   - Redirections: unquoted clobber (>|) or overwrite (>) to non-standard devices
   - Destructive overwrites: cp /dev/null, dd, tee
   - File tools: write_file zeroing existing non-empty files
2. Operations, arguments, globs or cwd touching .ssh (keys, configs, known_hosts)
3. SSH connections (ssh, scp, sftp, rsync over ssh / remote targets, git over ssh,
   nested invocations via wrappers, subshells or compound statements)
4. Dynamic inline script execution (python/ruby/node/perl -c/-e, eval, exec, git alias)

Contract:
- Restricted / Ambiguous: {"decision": "force_ask", "reason": "..."}
- Unclassified / Standard flow: {"decision": "ask"} (preserves normal accept-edits / engine permissions)
- Errors / invalid payloads: fail-closed with force_ask
"""

import json
import os
import re
import shlex
import sys

SSH_COMMANDS = {"ssh", "scp", "sftp"}
DELETE_COMMANDS = {"rm", "unlink", "shred", "rmdir", "trash-put"}
SSH_KEY_FILENAMES = {
    "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
    "authorized_keys", "known_hosts"
}

def touches_ssh(path_str, cwd=None):
    if not path_str or not isinstance(path_str, str):
        return False
    raw = path_str.strip().strip("'\"")
    if not raw:
        return False

    parts_raw = raw.replace("\\", "/").split("/")
    if ".ssh" in parts_raw:
        return True

    # Check dangerous hidden globs on home/root: e.g. .*/*, ~/.s*
    if re.search(r'(?:~|\$HOME|\/home\/[^\/]+|\/root)\/\.(?:s[a-z0-9_*-]*|\*)', raw):
        return True

    filename = parts_raw[-1]
    if filename in SSH_KEY_FILENAMES:
        return True
    if filename in ("config", "ssh_config") and any("ssh" in p.lower() for p in parts_raw):
        return True

    try:
        expanded = os.path.expanduser(raw)
        if not os.path.isabs(expanded) and cwd:
            resolved = os.path.realpath(os.path.join(cwd, expanded))
        else:
            resolved = os.path.realpath(expanded)
        resolved_parts = resolved.split(os.sep)
        if ".ssh" in resolved_parts:
            return True
        if resolved_parts[-1] in SSH_KEY_FILENAMES:
            return True
        if resolved_parts[-1] in ("config", "ssh_config") and any("ssh" in p.lower() for p in resolved_parts):
            return True
    except Exception:
        pass
    return False

def scan_obj_for_ssh(obj, cwd):
    if isinstance(obj, str):
        return touches_ssh(obj, cwd)
    elif isinstance(obj, list):
        return any(scan_obj_for_ssh(item, cwd) for item in obj)
    elif isinstance(obj, dict):
        return any(scan_obj_for_ssh(v, cwd) for v in obj.values())
    return False

def check_file_tool(tool_name, args, cwd):
    if not isinstance(args, dict):
        return "Invalid tool arguments"

    if scan_obj_for_ssh(args, cwd):
        return "Tool argument references .ssh path"

    # Whole-file zeroing check (only write_file overwriting existing non-empty file)
    if tool_name == "write_file":
        path = None
        for pk in ("Path", "TargetFile", "FilePath", "File", "AbsolutePath"):
            if pk in args and args[pk]:
                path = args[pk]
                break

        content = None
        for ck in ("Content", "CodeContent"):
            if ck in args:
                content = args[ck]
                break

        if path and content is not None and isinstance(content, str) and len(content.strip()) == 0:
            expanded = os.path.expanduser(path)
            if not os.path.isabs(expanded) and cwd:
                resolved = os.path.realpath(os.path.join(cwd, expanded))
            else:
                resolved = os.path.realpath(expanded)
            if os.path.exists(resolved) and os.path.isfile(resolved):
                try:
                    if os.path.getsize(resolved) > 0:
                        return f"Zeroing existing non-empty file ({path})"
                except OSError:
                    pass

    return None

def split_shell_commands(cmd_line):
    sub_cmds = []
    current = []
    in_single = False
    in_double = False
    escape = False

    i = 0
    n = len(cmd_line)
    while i < n:
        c = cmd_line[i]

        if escape:
            current.append(c)
            escape = False
            i += 1
            continue

        if c == '\\':
            current.append(c)
            escape = True
            i += 1
            continue

        if c == "'" and not in_double:
            in_single = not in_single
            current.append(c)
            i += 1
            continue

        if c == '"' and not in_single:
            in_double = not in_double
            current.append(c)
            i += 1
            continue

        # Outside single quotes, extract $(...) and `...`
        if not in_single:
            if c == '$' and i + 1 < n and cmd_line[i+1] == '(':
                depth = 1
                j = i + 2
                while j < n and depth > 0:
                    if cmd_line[j] == '\\':
                        j += 2
                        continue
                    if cmd_line[j] == '(':
                        depth += 1
                    elif cmd_line[j] == ')':
                        depth -= 1
                    j += 1
                if depth == 0:
                    inner = cmd_line[i+2:j-1]
                    sub_cmds.extend(split_shell_commands(inner))
                    current.append(cmd_line[i:j])
                    i = j
                    continue

            if c == '`':
                j = i + 1
                while j < n and cmd_line[j] != '`':
                    if cmd_line[j] == '\\':
                        j += 1
                    j += 1
                if j < n:
                    inner = cmd_line[i+1:j]
                    sub_cmds.extend(split_shell_commands(inner))
                    current.append(cmd_line[i:j+1])
                    i = j + 1
                    continue

        # Outside ALL quotes, check for command separators
        if not in_single and not in_double:
            if cmd_line[i:i+2] in ("&&", "||"):
                if current:
                    sub_cmds.append("".join(current).strip())
                    current = []
                i += 2
                continue

            if c == '|' and i > 0 and cmd_line[i-1] == '>':
                current.append(c)
                i += 1
                continue

            if c in (";", "|", "&", "\n", "(", ")"):
                if current:
                    sub_cmds.append("".join(current).strip())
                    current = []
                i += 1
                continue

            for kw in ("then", "do", "else", "elif", "fi", "done"):
                kw_len = len(kw)
                if cmd_line[i:i+kw_len] == kw:
                    left_ok = (i == 0 or cmd_line[i-1] in " \t\n;&|()")
                    right_ok = (i + kw_len >= n or cmd_line[i+kw_len] in " \t\n;&|()")
                    if left_ok and right_ok:
                        if current:
                            sub_cmds.append("".join(current).strip())
                            current = []
                        i += kw_len
                        break
            else:
                current.append(c)
                i += 1
                continue
            continue

        current.append(c)
        i += 1

    if current:
        sub_cmds.append("".join(current).strip())

    cleaned = []
    for sc in sub_cmds:
        s = sc.strip()
        if s.startswith("{") and s.endswith("}"):
            s = s[1:-1].strip()
        elif s.startswith("{") and len(s) > 1 and s[1].isspace():
            s = s[1:].strip()
        elif s.endswith("}") and len(s) > 1 and s[-2].isspace():
            s = s[:-1].strip()
        if s.startswith("if "):
            s = s[3:].strip()
        elif s.startswith("while "):
            s = s[6:].strip()
        elif s.startswith("until "):
            s = s[6:].strip()
        elif s.startswith("for ") and ";" in s:
            s = s.split(";", 1)[1].strip()
        if s:
            cleaned.append(s)

    return cleaned

def check_redirections(cmd_str, cwd):
    # Only match unquoted > or >|
    in_single = False
    in_double = False
    escape = False
    for i, c in enumerate(cmd_str):
        if escape:
            escape = False
            continue
        if c == "\\":
            escape = True
            continue
        if c == "'" and not in_double:
            in_single = not in_single
            continue
        if c == '"' and not in_single:
            in_double = not in_double
            continue
        if not in_single and not in_double and c == ">":
            if i > 0 and cmd_str[i-1] in "<>&\\|":
                continue
            if i + 1 < len(cmd_str) and cmd_str[i+1] in ">=&":
                continue
            m = re.match(r'(?:>\||>)\s*("[^"]*"|\'[^\']*\'|[^\s;&|<>]+)', cmd_str[i:])
            if m:
                target = m.group(1).strip("\'\"")
                if target not in ("/dev/null", "/dev/stdout", "/dev/stderr", "&1", "&2"):
                    return f"Shell file-overwriting redirection detected targeting '{target}'"
    return None

def unwrap_command_tokens(tokens):
    idx = 0
    wrappers = {
        "command", "sudo", "env", "nohup", "nice", "timeout", "xargs", "doas",
        "time", "strace", "ltrace"
    }

    while idx < len(tokens):
        tok = tokens[idx]

        # Strip standalone negation !
        if tok == "!":
            idx += 1
            continue

        # Strip curly braces { }
        if tok in ("{", "}"):
            idx += 1
            continue

        # Strip leading redirections (with or without space): 2> /dev/null, 2>/dev/null, < /dev/null, > out
        if re.match(r'^(?:\d+)?(?:>>?|<|>&|&>)$', tok):
            if idx + 1 < len(tokens):
                idx += 2
            else:
                idx += 1
            continue

        if re.match(r'^(?:\d+)?(?:>>?|<|>&|&>).+', tok):
            idx += 1
            continue

        # Strip environment variable assignments VAR=val
        if re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*=.*', tok):
            idx += 1
            continue

        base = os.path.basename(tok)
        if base in wrappers:
            idx += 1
            if base == "env":
                while idx < len(tokens):
                    if tokens[idx].startswith("-"):
                        if tokens[idx] in ("-u", "--unset") and idx + 1 < len(tokens):
                            idx += 2
                        else:
                            idx += 1
                    elif re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*=.*', tokens[idx]):
                        idx += 1
                    else:
                        break
            elif base == "timeout":
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    if tokens[idx] in ("-k", "-s", "--kill-after", "--signal") and idx + 1 < len(tokens):
                        idx += 2
                    else:
                        idx += 1
                if idx < len(tokens) and re.match(r'^\d+(?:\.\d+)?[smhd]?$', tokens[idx]):
                    idx += 1
            elif base == "nice":
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    if tokens[idx] in ("-n", "--adjustment") and idx + 1 < len(tokens):
                        idx += 2
                    else:
                        idx += 1
            elif base == "strace":
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    if tokens[idx] in ("-o", "-e", "-p", "-s", "-u", "-P") and idx + 1 < len(tokens):
                        idx += 2
                    else:
                        idx += 1
            elif base == "xargs":
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    if tokens[idx] in ("-I", "-n", "-P", "-d", "-E", "-s") and idx + 1 < len(tokens):
                        idx += 2
                    else:
                        idx += 1
            elif base in ("sudo", "doas"):
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    if tokens[idx] in ("-u", "-g", "-p", "-C") and idx + 1 < len(tokens):
                        idx += 2
                    else:
                        idx += 1
            elif base == "command":
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    idx += 1
            else:
                while idx < len(tokens) and tokens[idx].startswith("-"):
                    idx += 1
            continue
        break

    return tokens[idx:]

def check_single_command(cmd_str, cwd):
    redir_err = check_redirections(cmd_str, cwd)
    if redir_err:
        return redir_err

    if re.search(r'(?:git@[\w.-]+:|ssh:\/\/[\w.-]+)', cmd_str):
        return f"Git operation over SSH ({cmd_str})"

    try:
        tokens = shlex.split(cmd_str, posix=True)
    except ValueError as e:
        return f"Invalid shell syntax ({e})"

    if not tokens:
        return None

    # Check all tokens for .ssh references
    for tok in tokens:
        if touches_ssh(tok, cwd):
            return f"Command argument references .ssh path '{tok}'"

    tokens = unwrap_command_tokens(tokens)
    if not tokens:
        return None

    cmd_base = os.path.basename(tokens[0])

    # Direct SSH
    if cmd_base in SSH_COMMANDS:
        return f"SSH connection command '{cmd_base}'"

    # Dynamic interpreters (versioned like python3.12, ruby3)
    if re.match(r'^(?:python|ruby|node|perl|php)\d*(?:\.\d+)*$', cmd_base):
        for t in tokens[1:]:
            if t in ("-c", "-e") or t.startswith("-c") or t.startswith("-e"):
                return f"Dynamic inline script execution ({cmd_base})"

    # Dynamic shell execution
    if cmd_base in ("eval", "exec"):
        return f"Dynamic shell execution ({cmd_base})"

    # Shell invocations: sh, bash, zsh with -c, -lc, etc.
    if cmd_base in ("sh", "bash", "zsh", "dash", "ksh"):
        for i, t in enumerate(tokens[1:], start=1):
            if t == "-c" or (t.startswith("-") and "c" in t):
                if i + 1 < len(tokens):
                    sub_line = tokens[i + 1]
                    sub_check = check_command_line(sub_line, cwd)
                    if sub_check:
                        return f"Nested shell command: {sub_check}"
                break

    # Deletions: rm, unlink, shred, rmdir
    if cmd_base in DELETE_COMMANDS:
        return f"File deletion command '{cmd_base}'"

    # Truncation via cp /dev/null
    if cmd_base == "cp" and any("/dev/null" in t for t in tokens[1:]):
        return "Truncating file via cp /dev/null"

    # Overwrite via dd
    if cmd_base == "dd":
        return "Low-level dd command"

    # Overwrite via tee
    if cmd_base == "tee":
        return "File writing via tee"

    # git
    if cmd_base == "git":
        if any(t.startswith("alias.") for t in tokens[1:]):
            return "Git with custom alias configuration"
        i = 1
        while i < len(tokens):
            t = tokens[i]
            if t in ("-C", "--git-dir", "--work-tree", "--exec-path") and i + 1 < len(tokens):
                i += 2
            elif t.startswith("-C") or t.startswith("--git-dir=") or t.startswith("--work-tree="):
                i += 1
            elif t == "-c" and i + 1 < len(tokens):
                i += 2
            elif t.startswith("-"):
                i += 1
            else:
                break
        if i < len(tokens):
            git_sub = tokens[i]
            if git_sub == "rm":
                return "git rm command"
            if git_sub == "clean":
                return "git clean command"
            if git_sub == "reset" and any(arg == "--hard" for arg in tokens[i+1:]):
                return "git reset --hard command"

    # find
    if cmd_base == "find":
        if any(arg == "-delete" for arg in tokens[1:]):
            return "find with -delete"
        for i, arg in enumerate(tokens):
            if arg in ("-exec", "-execdir", "-ok", "-okdir") and i + 1 < len(tokens):
                end_idx = len(tokens)
                if tokens[-1] in (";", "\\;", "+"):
                    end_idx -= 1
                exec_tokens = tokens[i+1:end_idx]
                if exec_tokens:
                    base = os.path.basename(exec_tokens[0])
                    if base in DELETE_COMMANDS:
                        return f"find with -exec {base}"
                    cmd_to_check = " ".join(shlex.quote(t) for t in exec_tokens)
                    sub_check = check_command_line(cmd_to_check, cwd)
                    if sub_check:
                        return f"find with nested command: {sub_check}"

    # truncate
    if cmd_base == "truncate":
        return "truncate command"

    # rsync
    if cmd_base == "rsync":
        args_str = " ".join(tokens[1:])
        rsync_delete_flags = {
            "--delete", "--del", "--delete-before", "--delete-after",
            "--delete-during", "--delete-delay", "--delete-excluded",
            "--delete-missing-args", "--remove-source-files"
        }
        if any(arg in rsync_delete_flags for arg in tokens[1:]):
            return "rsync file deletion flag detected"
        if re.search(r'(?:-e\s*["\']?ssh|\bssh\b)', args_str):
            return "rsync over SSH"
        for arg in tokens[1:]:
            if not arg.startswith("-") and ":" in arg:
                return f"rsync with remote target '{arg}'"

    return None

def check_command_line(cmd_line, cwd):
    if not isinstance(cmd_line, str) or not cmd_line.strip():
        return "Missing or empty command line"

    sub_cmds = split_shell_commands(cmd_line)
    for sc in sub_cmds:
        res = check_single_command(sc, cwd)
        if res:
            return res
    return None

def main():
    try:
        raw_input = sys.stdin.read()
        if not raw_input.strip():
            print(json.dumps({"decision": "force_ask", "reason": "Safety Guard: empty hook payload"}))
            return

        payload = json.loads(raw_input)
        if not isinstance(payload, dict):
            print(json.dumps({"decision": "force_ask", "reason": "Safety Guard: payload is not a JSON object"}))
            return

        cwd = payload.get("cwd", os.getcwd())
        if touches_ssh(cwd):
            print(json.dumps({"decision": "force_ask", "reason": f"Safety Guard: Current working directory is inside .ssh ({cwd})"}))
            return

        call = payload.get("toolCall")
        if not call or not isinstance(call, dict):
            print(json.dumps({"decision": "force_ask", "reason": "Safety Guard: missing toolCall in payload"}))
            return

        tool_name = call.get("name")
        if not tool_name:
            print(json.dumps({"decision": "force_ask", "reason": "Safety Guard: missing tool name in toolCall"}))
            return

        args = call.get("args")
        if not isinstance(args, dict):
            print(json.dumps({"decision": "force_ask", "reason": "Safety Guard: missing or invalid tool arguments"}))
            return

        reason = None
        if tool_name == "run_command":
            cmd = args.get("CommandLine")
            if not cmd:
                reason = "Missing CommandLine in run_command"
            else:
                reason = check_command_line(cmd, cwd)
        else:
            reason = check_file_tool(tool_name, args, cwd)

        if reason:
            print(json.dumps({
                "decision": "force_ask",
                "reason": f"Safety Guard: {reason}"
            }))
        else:
            print(json.dumps({"decision": "ask"}))
    except Exception as e:
        # Fail closed
        print(json.dumps({
            "decision": "force_ask",
            "reason": f"Safety Guard error: {str(e)}"
        }))

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Claude Code hook -> writes one status file per session for ClaudeNotifier.app.

Usage (from settings.json hooks): hook.py <EventName>
       hook.py --install | --uninstall | --status   (edit ~/.claude/settings.json)
Never prints to stdout (UserPromptSubmit stdout would leak into Claude's context).
"""
import json
import os
import subprocess
import sys
import time

STATE = os.path.expanduser("~/.claude/claude-notifier/state")
SHELLS = {"sh", "bash", "zsh", "dash", "fish"}


def claude_pid():
    """Walk up past any wrapper shell to the long-lived claude process."""
    pid = os.getppid()
    for _ in range(3):
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=1).stdout.strip()
            ppid, comm = out.split(None, 1)
        except Exception:
            return pid
        if os.path.basename(comm).lstrip("-") in SHELLS:
            pid = int(ppid)
        else:
            return pid
    return pid


def project_root(cwd):
    """Nearest ancestor that Studio opens as a project (.idea), else gradle root, else cwd."""
    for markers in ((".idea",), ("settings.gradle", "settings.gradle.kts"), (".git",)):
        d = cwd
        while d and d not in ("/", os.path.expanduser("~")):
            if any(os.path.exists(os.path.join(d, m)) for m in markers):
                return d
            d = os.path.dirname(d)
    return cwd


SETTINGS = os.path.expanduser("~/.claude/settings.json")
EVENTS = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Notification", "SessionEnd"]


def ours(entry):
    return any("claude-notifier/hook.py" in h.get("command", "") for h in entry.get("hooks", []))


def manage(action):
    try:
        with open(SETTINGS) as f:
            s = json.load(f)
    except FileNotFoundError:
        s = {}
    hooks = s.setdefault("hooks", {})
    installed = all(any(ours(e) for e in hooks.get(ev, [])) for ev in EVENTS)
    if action == "--status":
        print("installed" if installed else "missing")
        return
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as src, open(SETTINGS + ".bak-notifier", "w") as dst:
            dst.write(src.read())
    for ev in EVENTS:
        lst = [e for e in hooks.get(ev, []) if not ours(e)]
        if action == "--install":
            entry = {"hooks": [{"type": "command", "timeout": 5,
                                "command": f'python3 "$HOME/.claude/claude-notifier/hook.py" {ev}'}]}
            if ev == "PostToolUse":
                entry["matcher"] = "*"
            lst.append(entry)
        if lst:
            hooks[ev] = lst
        else:
            hooks.pop(ev, None)
    if not hooks:
        s.pop("hooks")
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    tmp = SETTINGS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, SETTINGS)
    print("ok")


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    sid = data.get("session_id") or "unknown"
    os.makedirs(STATE, exist_ok=True)
    path = os.path.join(STATE, sid + ".json")

    if event == "SessionEnd":
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return

    try:
        with open(path) as f:
            cur = json.load(f)
    except Exception:
        cur = {}
    cur_status = cur.get("status")

    if event in ("UserPromptSubmit", "PostToolUse"):
        if event == "PostToolUse" and cur_status == "working":
            return  # nothing changed; skip the write
        status, msg = "working", "Working…"
    elif event == "Stop":
        status, msg = "done", "Task finished"
    elif event == "Notification":
        msg = data.get("message") or "Needs your input"
        ntype = data.get("notification_type", "")
        idle = ntype == "idle_prompt" or "waiting for your input" in msg.lower()
        if idle and cur_status == "done":
            return  # already flagged as finished; don't downgrade to "input"
        status = "input"
    elif event == "SessionStart":
        if cur_status:
            return
        status, msg = "idle", "Session started"
    else:
        return

    cwd = data.get("cwd") or os.getcwd()
    root = cur.get("project_path") or project_root(cwd)
    rec = {
        "session_id": sid,
        "project": os.path.basename(root) or root,
        "project_path": root,
        "cwd": cwd,
        "status": status,
        "message": msg,
        "ts": time.time(),
        "bundle_id": cur.get("bundle_id") or os.environ.get("__CFBundleIdentifier", ""),
        "pid": cur.get("pid") or claude_pid(),
    }
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f)
    os.replace(tmp, path)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1].startswith("--"):
        manage(sys.argv[1])  # setup commands: let errors surface
        sys.exit(0)
    try:
        main()
    except Exception:
        pass  # a notifier must never break Claude

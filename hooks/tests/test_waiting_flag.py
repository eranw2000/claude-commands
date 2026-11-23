#!/usr/bin/env python3
"""hooks/waiting-flag.sh: which flag a Stop leaves, so the status line says the right thing.

Runs the real hook with HOME pointed at a temp folder.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HOOK = os.environ.get(
    "HOOK_UNDER_TEST", os.path.expanduser("~/.claude/hooks/waiting-flag.sh"))
SID = "11111111-2222-3333-4444-555555555555"


def find_bash():
    """Claude Code runs hooks in Git Bash on Windows. A plain `bash` there can be the WSL
    launcher in System32, so take the bash.exe that ships beside git.exe first."""
    if os.name != "nt":
        return "bash"
    git = shutil.which("git")
    cands = []
    if git:
        root = os.path.dirname(os.path.dirname(os.path.realpath(git)))
        cands.append(os.path.join(root, "bin", "bash.exe"))
    cands.append(os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                              "Git", "bin", "bash.exe"))
    for c in cands:
        if os.path.isfile(c):
            return c
    return "bash"


BASH = find_bash()


def run(mode, event, msg, home):
    data = {"session_id": SID, "hook_event_name": event, "last_assistant_message": msg}
    env = dict(os.environ, HOME=home)
    subprocess.run([BASH, HOOK, mode], input=json.dumps(data), text=True,
                   env=env, check=True, timeout=30)
    d = os.path.join(home, ".claude", ".statusline-state")
    return (os.path.exists(os.path.join(d, "waiting-" + SID)),
            os.path.exists(os.path.join(d, "working-" + SID)))


WORKING = (False, True)
WAITING = (True, False)
CASES = [
    # a turn that ends on a bare "You: nothing yet."
    ("set", "Stop", "**Done:** pin.\n\n**Now:** suite.\n\n**You:** nothing yet.", WORKING),
    ("set", "Stop", "**You:** nothing yet, I'm still working.", WORKING),
    ("set", "Stop", "You: nothing yet. I" + chr(0x2019) + "m still working.", WORKING),
    # twins that must stay "waiting"
    ("set", "Stop", "**You:** your turn. Pick one: 1, 2 or 3.", WAITING),
    ("set", "Stop", "Nothing yet has been deployed. **You:** run the release.", WAITING),
    ("set", "Notification", "**You:** nothing yet.", WAITING),
]

fails = 0
for mode, event, msg, want in CASES:
    with tempfile.TemporaryDirectory() as home:
        got = run(mode, event, msg, home)
    ok = got == want
    fails += not ok
    print(("ok   " if ok else "FAIL ") + f"{event}: {msg[-45:]!r} -> waiting={got[0]} working={got[1]}")

with tempfile.TemporaryDirectory() as home:
    run("set", "Stop", "**You:** nothing yet.", home)
    got = run("clear", "UserPromptSubmit", "", home)
ok = got == (False, False)
fails += not ok
print(("ok   " if ok else "FAIL ") + "clear removes both flags")

print(f"{len(CASES) + 1 - fails}/{len(CASES) + 1} passed")
sys.exit(1 if fails else 0)

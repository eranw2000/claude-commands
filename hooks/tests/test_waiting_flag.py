#!/usr/bin/env python3
"""hooks/waiting-flag.sh: which flag a Stop leaves, so the status line says the right thing.

Runs the real hook with HOME pointed at a temp folder.
"""
import json
import os
import subprocess
import sys
import tempfile

HOOK = os.environ.get(
    "HOOK_UNDER_TEST", os.path.expanduser("~/.claude/hooks/waiting-flag.sh"))
SID = "11111111-2222-3333-4444-555555555555"


def run(mode, event, msg, home):
    data = {"session_id": SID, "hook_event_name": event, "last_assistant_message": msg}
    env = dict(os.environ, HOME=home)
    subprocess.run(["bash", HOOK, mode], input=json.dumps(data), text=True,
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

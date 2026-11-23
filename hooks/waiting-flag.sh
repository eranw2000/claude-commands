#!/bin/bash
# The "waiting for your inputs..." flag that statusline.sh shows, so you can tell
# whether a session is waiting for you or still working.
#
#   waiting-flag.sh set     Stop, Notification (permission / needs input), PreToolUse AskUserQuestion
#   waiting-flag.sh clear   UserPromptSubmit, PostToolUse (any tool: work has started again)
#
# On Stop only: when the turn's final message says "I'm still working", or has a line
# "You: nothing yet" (useful if your CLAUDE.md asks Claude to end each turn with a `You:`
# line saying what you must do), the "working" flag is set instead, and the status line
# shows "I'm still working...". The text comes from the Stop input's
# last_assistant_message: "The `last_assistant_message` field contains the text content of
# Claude's final response, so hooks can access it without parsing the transcript file."
# (https://code.claude.com/docs/en/hooks.md, Stop input).
#
# One empty file per session, named after the session id, beside the status line's own state.
# Never blocks and never prints: a hook that fails here must not get in the way of a turn.
mode="$1"
input=$(cat)
sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
case "$sid" in ''|*[!A-Za-z0-9-]*) exit 0 ;; esac
dir="$HOME/.claude/.statusline-state"
flag="$dir/waiting-$sid"
work="$dir/working-$sid"
still_working() {
  # Exit 0 only for a Stop whose final message says "I'm still working" (any apostrophe), or
  # whose `You:` line says "nothing yet" (Markdown bold allowed): that line is only used while
  # work still runs.
  # Any Python 3 on the PATH (Git Bash on Windows often has only `python`).
  py=$(command -v python3 || command -v python || echo /usr/bin/python3)
  printf '%s' "$input" | "$py" -c '
import json, re, sys
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"), strict=False)
except Exception:
    sys.exit(1)
if d.get("hook_event_name") != "Stop":
    sys.exit(1)
msg = d.get("last_assistant_message") or ""
sys.exit(0 if re.search(r"\bI.m still working|\bYou:\W*nothing yet", msg, re.I) else 1)
' 2>/dev/null
}
case "$mode" in
  set)
    mkdir -p "$dir" 2>/dev/null || exit 0
    if still_working; then
      rm -f "$flag" 2>/dev/null; : > "$work" 2>/dev/null
    else
      rm -f "$work" 2>/dev/null; : > "$flag" 2>/dev/null
    fi ;;
  clear) rm -f "$flag" "$work" 2>/dev/null ;;
esac
exit 0

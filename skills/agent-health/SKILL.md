---
name: agent-health
description: Check whether the agents working on a project are alive and healthy, and say plainly whether to keep waiting. Covers headless runs (`claude -p`), the helper agents they spawn, their child processes (tests, git), and background commands a session started, and it reads the Mac's last wake from sleep so silence while the laptop was closed is not mistaken for a hang. Use when the user asks "are the agents alive", "are the agents healthy", "is it still running", "is something wrong, it takes too long", "did it die", "should I wait", or comes back after a long break or after closing and opening the laptop. It never kills, restarts or resumes anything; when a run is still working it arms one finish ping (also on "ping me when it finishes").
model: sonnet
---

# Agent health

The user has been away, or the laptop slept, and wants one answer: **is the work still moving, and should they
wait?** This skill checks and answers. It never kills a process, restarts a run or resumes anything. The one
thing it starts is the finish watcher in step 2.

## 1. Find the project folder

The script needs the **folder the work was launched from**: the working directory of the sessions and
`claude -p` runs to check, because their transcripts are keyed to it.

- When this session runs in that folder, use the current directory.
- Several plausible folders, or none: list them and ask. Never guess; a check of the wrong folder reports "nothing
  running" about work that is running elsewhere.

## 2. Run the check

```sh
python3 ~/.claude/skills/agent-health/agent_health.py "<project dir>" --ping-when-done \
  > "${TMPDIR:-/tmp}/agent_health.txt" 2>&1; echo "exit=$?"
```

Give the Bash call `timeout: 300000` (reading the power log can take a minute) and `dangerouslyDisableSandbox: true`
(the sandbox hides other processes' working folders, so it would see no run, and it would end the watcher with the
call). Read the output file afterwards.

**`--ping-when-done` is the one thing here that is not read-only.** When a headless run is still alive, it
starts ONE detached watcher for the folder and prints `PING ARMED` (or `PING ALREADY ARMED` when one is
running). The watcher waits until no `claude -p` is left in the folder, then shows a macOS notification and
plays a system sound (set `AGENT_HEALTH_SOUND` to another sound file to change it). It gives up after
`--max-hours` (default 24) and says so. State and log: `~/.local/state/agent-health/`. It watches
headless runs; helper agents of an interactive session report to their own session.
Exit 0 means nothing is stalled, 1 means something is STALLED, 2 means the check itself failed. Options:
`--quiet N` (minutes of silence before a live run counts as stalled, default 20), `--hours N` (look-back, default 24).

Also call `ListAgents` (load it with ToolSearch if deferred) for helper agents THIS session started; the script reads
other sessions' helpers from their transcripts.

## 3. What each verdict means

| Verdict | Meaning | Tell the user |
|---|---|---|
| WORKING | the run or one of its helpers wrote within the quiet window | wait |
| WAITING | quiet, but a child process is running (a test suite, git), or a session started a background command that has not reported back yet | wait; name the child or the command |
| JUST WOKE | the Mac woke inside the quiet window and the run was quiet before it | wait one quiet window, then re-check |
| STALLED | alive, silent longer than the window, no working child | re-check once after another window; still stalled means look at its transcript tail before anything else |
| NOTHING RUNNING | no headless run, and no background command still running for this folder | say so, and name the folder checked |

**Sleep is not a hang.** macOS suspends every process while the laptop sleeps, so a run that was busy before the lid
closed shows a long silence and resumes on its own after the wake. Judge silence only from the last wake onward; the
script prints the wake time, and JUST WOKE covers the first window after it.

**A quiet main session is normal.** A run often hands work to a helper agent and waits; its own log goes
silent while the helper's log moves. The script counts the newest write by the run OR any of its helpers.

## 4. Answer

Lead with the three lines, in plain words, then the evidence:

- `Done:` what the run has finished since the user last looked.
- `Now:` the verdict and what is moving (which helper or child, last write time in UTC and local time).
- `You:` "nothing, wait" or the one action (re-check in N minutes). When the output says `PING ARMED` or
  `PING ALREADY ARMED`, add: "you will get a notification when it finishes".

Name the folder you checked and the time you checked it. If the check exited 2, say the check failed and why;
never report "healthy" from a check that did not run.

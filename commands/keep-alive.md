---
model: inherit
description: "Every 30 minutes, check this session's helper agents, background commands and headless runs. While anything is running, report it in three lines (each tick also keeps the session's prompt cache warm). Once all are finished and nobody has written since the last tick, run /save-context in full, then stop the timer. Use when the user says 'keep-alive', 'keep the session alive', 'keep the cache warm while the agents work', or '/keep-alive stop'."
argument-hint: "[start | tick | stop]  (default: start)"
---

# keep-alive

A session-only timer that wakes this session every 30 minutes. Each wake is a turn, and a
turn that hits the cache resets its one-hour timer ("Each request that hits the cache resets
the timer, so the cache stays warm as long as you keep working.",
https://code.claude.com/docs/en/prompt-caching.md). When the work it is waiting for is done,
it saves the session and switches itself off.

The command has no `model:` pin on purpose. The prompt cache belongs to one model, so a
tick that ran on another model would read the whole session cold and leave this model's
cache unrefreshed. For the same reason the agent-health and save-context skills are FOLLOWED
from their files, never invoked with the Skill tool (agent-health is pinned to sonnet).

Argument: `$ARGUMENTS` (blank means `start`).

## start

1. Load `CronCreate`, `CronList`, `CronDelete` and `ListAgents` in ONE `ToolSearch` call.
2. `CronList`. If a job whose prompt is `/keep-alive tick` already exists, say so with its id
   and do not create a second one.
3. Otherwise `CronCreate` with `cron: "13,43 * * * *"` (every 30 minutes, off the :00 and :30
   marks), `prompt: "/keep-alive tick"`, `recurring: true`.
4. Tell the user in plain words: the job id, that it fires only while the session is idle, that it
   lives only in this session (closing the session ends it), and that it expires by itself
   after 7 days.
5. Run one `tick` now, so the first answer does not wait 30 minutes.

## tick

Do only this. Start no other work from a tick, and answer with three lines: `Done:` what
finished, `Now:` what is still running, `You:` what the user must do, or "nothing".

1. **What is still running.** Read `~/.claude/skills/agent-health/SKILL.md` in full and follow its
   steps 1 to 3 as written, including `--ping-when-done` (it arms at most ONE watcher per
   folder and says `PING ALREADY ARMED` on later ticks, so a repeat tick adds nothing). Note
   every verdict that is not `NOTHING RUNNING`. Then list what THIS session started in the
   background and has not yet seen finish: helper agents (`ListAgents`, and the completion
   notice each one sends) and background shell commands and monitors (a `run_in_background`
   call with no completion notice yet). A watch that this session re-arms after each round (a
   `wait` loop on a remote job) counts as running while its latest round has no notice.
2. **What is half done.** A question still waiting for the user's answer, or a flow stopped
   half way: a rebase or merge in progress, a release between its steps, a failed command
   this session has not dealt with yet.
3. **Decide.**
   - **Something needs the user** (agent-health says `STALLED` on two ticks in a row, a helper
     or run failed, or anything from step 2): answer with the three lines, the `You:` line
     naming the one action, and stop. Do not save, keep ticking.
   - **Something is still running** (`WORKING`, `WAITING`, `JUST WOKE`, a first `STALLED`, or
     any running item from step 1): answer with the three lines only (`Done:`, `Now:` naming
     each running item, `You: nothing`). Do not save. Stop.
   - **Nothing is running and nothing needs the user:** go on.
4. **Has the user written since the previous tick?** Look for a genuine message from the user
   after the previous `/keep-alive tick` turn. A cron prompt, a task notification, a hook
   message and a subagent hand-back are NOT the user. If they wrote, they are active: answer
   `Now: you are active, no save.` and stop.
5. **Save if the save is behind.** Find the last `/save-context` run in this conversation. If
   any work, result or notice came after it, or it never ran (ticks that only reported state
   do not count), read `~/.claude/skills/save-context/SKILL.md` and execute every step in it,
   in full, in this turn. Otherwise skip the save and say the last save already covers
   everything. If that file does not exist, skip the save and say `/save-context` is not
   installed.
6. **Switch off.** `CronList`, then `CronDelete` the `/keep-alive tick` job, because there is
   nothing left to wait for. Then write, in bold:
   `**DONE: all agents and background commands finished, keep-alive stopped. You: nothing (run /keep-alive to start it again)**`

## stop

`CronList`, `CronDelete` every job whose prompt is `/keep-alive tick`, and confirm with the
id(s) removed. Say "no keep-alive job was running" when there was none.

## What it costs

Each tick re-reads the whole session from the cache, billed as cache reads, not new writes.
The timer stops itself once the work is done, so it does not keep ticking.

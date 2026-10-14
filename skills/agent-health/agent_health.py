#!/usr/bin/env python3
"""Is the work running for one Claude project alive, waiting or stalled?

Read-only, apart from the optional finish watcher below. It never kills, restarts or resumes anything.

It looks at, for the given folder (the working directory the sessions were launched from):
  - headless runs (`claude -p`) whose working directory is that folder, matched to their own transcript by
    start time, plus every process they spawned;
  - every session transcript of the folder written in the last --hours, and its helper agents' transcripts,
    plus any background command a session started that has not reported back yet (counted as WAITING);
  - the Mac's last wake from sleep, so silence that is really the laptop sleeping is not read as a hang.

Verdict per headless run:
  WORKING   it or one of its helpers wrote within --quiet minutes
  WAITING   nothing written in that window, but a child process (tests, git, python) is running
  JUST WOKE the Mac woke less than --quiet minutes ago and the run was quiet before that; give it time
  STALLED   alive, nothing written for longer than --quiet minutes, no working child process

Exit: 0 nothing stalled; 1 something STALLED; 2 the check itself failed.

--ping-when-done is the one thing that is not read-only: when a headless run is still alive it starts ONE
detached watcher per folder (state in ~/.local/state/agent-health/) and returns. The watcher waits until no
`claude -p` is left in the folder, then shows a macOS notification and plays a system sound
(AGENT_HEALTH_SOUND, default Glass). It gives up after --max-hours and says so.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
import time

UTC = dt.timezone.utc
NOW = dt.datetime.now(UTC)
HOME = os.path.expanduser("~")
STATE_DIR = os.environ.get("AGENT_HEALTH_STATE", os.path.join(HOME, ".local", "state", "agent-health"))
SOUND = os.environ.get("AGENT_HEALTH_SOUND", "/System/Library/Sounds/Glass.aiff")
# Processes a session keeps for its whole life; they say nothing about whether work is moving.
IDLE_CHILDREN = re.compile(r"mcp|context7|npm exec|/bin/zsh -c source .*shell-snapshots.*\|\| tru|caffeinate")


def sh(args, timeout=60):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def ago(t):
    if t is None:
        return "never"
    m = max(0, int((NOW - t).total_seconds() // 60))
    return f"{m} min ago" if m < 120 else f"{m // 60}h{m % 60:02d}m ago"


def local(t):
    return t.astimezone().strftime("%H:%M") if t else "-"


def utc(t):
    return t.astimezone(UTC).strftime("%H:%M") if t else "-"


def stamp(t):
    """A time as both zones: the logs are UTC, you read local time."""
    return f"{utc(t)} UTC / {local(t)} local" if t else "-"


def mtime(path):
    try:
        return dt.datetime.fromtimestamp(os.path.getmtime(path), UTC)
    except OSError:
        return None


def encoded(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def last_wake():
    """The last full wake from sleep, from the power log (macOS). None where pmset is unavailable."""
    last = None
    for line in sh(["pmset", "-g", "log"], timeout=90).splitlines():
        m = re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}) Wake\s+\t", line)
        if m:
            last = m.group(1)
    return dt.datetime.strptime(last, "%Y-%m-%d %H:%M:%S %z").astimezone(UTC) if last else None


def etime_seconds(s):
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = [int(p) for p in s.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, sec = parts
    return days * 86400 + h * 3600 + m * 60 + sec


def processes():
    procs = {}
    for line in sh(["ps", "-axo", "pid=,ppid=,etime=,pcpu=,command="]).splitlines():
        f = line.split(None, 4)
        if len(f) < 5:
            continue
        pid, ppid, et, cpu, cmd = int(f[0]), int(f[1]), f[2], float(f[3]), f[4]
        procs[pid] = {"pid": pid, "ppid": ppid, "secs": etime_seconds(et), "cpu": cpu, "cmd": cmd}
    return procs


def descendants(pid, procs):
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        for q in procs.values():
            if q["ppid"] == p:
                out.append(q)
                todo.append(q["pid"])
    return out


def proc_cwd(pid):
    for line in sh(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"]).splitlines():
        if line.startswith("n"):
            return line[1:]
    return ""


def transcript_head(path):
    """(first timestamp, entrypoint) of a session transcript."""
    first, entry = None, ""
    try:
        with open(path) as fh:
            for i, line in enumerate(fh):
                if i > 40:
                    break
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if first is None and d.get("timestamp"):
                    first = dt.datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00"))
                if d.get("entrypoint"):
                    entry = d["entrypoint"]
                    break
    except OSError:
        pass
    return first, entry


def sessions(project_dir, hours):
    tdir = os.path.join(HOME, ".claude", "projects", encoded(project_dir))
    out = []
    for f in glob.glob(os.path.join(tdir, "*.jsonl")):
        last = mtime(f)
        if last is None or (NOW - last).total_seconds() > hours * 3600:
            continue
        sid = os.path.basename(f)[:-6]
        first, entry = transcript_head(f)
        subs = glob.glob(os.path.join(tdir, sid, "subagents", "*.jsonl"))
        sub_last = max((mtime(s) for s in subs), default=None)
        out.append({"id": sid, "path": f, "last": last, "first": first, "entry": entry,
                    "helpers": len(subs), "helper_last": sub_last,
                    "pending": pending_background(f)})
    return sorted(out, key=lambda s: s["last"], reverse=True)


BG_STARTED = re.compile(r"Command running in background with ID: ([A-Za-z0-9]+)")
TASK_ID = re.compile(r"<task-id>([A-Za-z0-9]+)</task-id>")


def _text_of(content):
    """The plain text of a message's content, whether a string or a list of blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def pending_background(path):
    """Background commands a session started that have no finish notice yet:
    [{"id", "description", "started"}], oldest first.

    A session that runs a test suite in the background goes quiet while the suite runs,
    and no `claude -p` exists for it, so this is what keeps a live suite from reading
    as NOTHING RUNNING. A start is the RESULT of a Bash call made with
    `run_in_background`; the end is a `<task-notification>` naming the same task id,
    queued for the session or delivered in a user turn. Only those two places are read:
    a grep whose OUTPUT happens to contain either phrase must not start or end a task.
    """
    background_calls, started, done = {}, {}, set()
    try:
        lines = open(path, errors="replace")
    except OSError:
        return []
    with lines:
        for line in lines:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") == "queue-operation":
                done.update(TASK_ID.findall(str(d.get("content", ""))))
                continue
            msg = d.get("message") or {}
            content = msg.get("content")
            if msg.get("role") == "user":
                done.update(TASK_ID.findall(_text_of(content)))
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if (block.get("type") == "tool_use"
                        and (block.get("input") or {}).get("run_in_background")):
                    background_calls[block.get("id")] = (block.get("input") or {}).get("description", "")
                elif block.get("type") == "tool_result" and block.get("tool_use_id") in background_calls:
                    for tid in BG_STARTED.findall(json.dumps(block.get("content"))):
                        started.setdefault(tid, (background_calls[block["tool_use_id"]], d.get("timestamp")))
    out = []
    for tid, (desc, ts) in started.items():
        if tid in done:
            continue
        try:
            when = dt.datetime.fromisoformat(ts.replace("Z", "+00:00")) if ts else None
        except ValueError:
            when = None
        out.append({"id": tid, "description": desc, "started": when})
    return sorted(out, key=lambda p: p["started"] or NOW)


def live_headless(project_dir, procs):
    """Every `claude -p` whose working directory is this project folder."""
    return [p for p in procs.values() if re.search(r"(^|/)claude -p\b", p["cmd"])
            and proc_cwd(p["pid"]).rstrip("/") == project_dir.rstrip("/")]


def finish_outcome(project_dir):
    """(mode, message) for the moment no headless run is left in the folder."""
    return "done", f"agents on {os.path.basename(project_dir)} have finished"


def notify(mode, message):
    """A macOS notification plus a system sound. Nothing happens on other systems."""
    if sys.platform != "darwin" or os.environ.get("AGENT_HEALTH_NO_BANNER") == "1":
        return
    safe = message.replace("\\", "\\\\").replace('"', '\\"')
    title = "Agents finished" if mode == "done" else "Agent health"
    for cmd in (["osascript", "-e", f'display notification "{safe}" with title "{title}"'], ["afplay", SOUND]):
        try:
            subprocess.run(cmd, capture_output=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            pass


def state_file(project_dir):
    # realpath: the watcher resolves its folder (/var -> /private/var), so both sides must name the same file.
    return os.path.join(STATE_DIR, encoded(os.path.realpath(project_dir)) + ".json")


def watch(project_dir, poll, max_hours):
    """Wait until no headless run is left in the folder (two empty polls in a row), then ping once."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(state_file(project_dir), "w") as fh:
            json.dump({"pid": os.getpid(), "armed": stamp(dt.datetime.now(UTC))}, fh)
    except OSError:
        pass
    deadline = time.time() + max_hours * 3600
    empty = 0
    while time.time() < deadline:
        procs = processes()
        if procs and not live_headless(project_dir, procs):
            empty += 1
            if empty >= 2:
                mode, msg = finish_outcome(project_dir)
                break
        else:
            empty = 0
        time.sleep(poll)
    else:
        mode, msg = "attention", f"agent-health stopped watching {os.path.basename(project_dir)} after {max_hours:g}h; still running"
    print(f"{dt.datetime.now(UTC).isoformat()} {mode}: {msg}", flush=True)
    notify(mode, msg)
    try:
        os.remove(state_file(project_dir))
    except OSError:
        pass
    return 0


def arm(project_dir, procs, poll, max_hours):
    """Start one detached watcher for this folder, unless a live one is already there."""
    os.makedirs(STATE_DIR, exist_ok=True)
    sf = state_file(project_dir)
    try:
        w = json.load(open(sf))
        if "agent_health.py" in procs.get(w["pid"], {}).get("cmd", ""):
            return f"PING ALREADY ARMED: watcher pid {w['pid']}, armed {w['armed']}"
    except (OSError, ValueError, KeyError, TypeError):
        pass
    # Written BEFORE the watcher starts: a watcher that finishes fast removes this file, and a write after the
    # spawn would then leave a stale one. The watcher records its own pid in it when it starts.
    with open(sf, "w") as fh:
        json.dump({"pid": None, "armed": stamp(NOW)}, fh)
    log = open(sf[:-5] + ".log", "a")
    p = subprocess.Popen([sys.executable, os.path.abspath(__file__), project_dir, "--watch",
                          "--poll", str(poll), "--max-hours", str(max_hours)],
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    return (f"PING ARMED: watcher pid {p.pid} pings when no headless run is left in this folder "
            f"(checks every {poll:g}s, gives up after {max_hours:g}h)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("project_dir", nargs="?", default=os.getcwd(),
                    help="the Claude project directory the work was launched from (default: current directory)")
    ap.add_argument("--quiet", type=float, default=20, help="minutes of silence before a live run counts as stalled")
    ap.add_argument("--hours", type=float, default=24, help="look at sessions written in this many hours")
    ap.add_argument("--ping-when-done", action="store_true",
                    help="if a headless run is alive, start one detached watcher that pings when none is left")
    ap.add_argument("--watch", action="store_true", help="internal: be that watcher")
    ap.add_argument("--poll", type=float, default=60, help="watcher: seconds between checks")
    ap.add_argument("--max-hours", type=float, default=24, help="watcher: give up (and ping) after this long")
    args = ap.parse_args()
    project_dir = os.path.realpath(os.path.expanduser(args.project_dir))
    if not os.path.isdir(project_dir):
        print(f"ERROR: {project_dir} is not a directory", file=sys.stderr)
        return 2
    if args.watch:
        return watch(project_dir, args.poll, args.max_hours)

    procs = processes()
    if not procs:
        print("ERROR: could not list processes (ps returned nothing)", file=sys.stderr)
        return 2
    wake = last_wake()
    quiet_from = NOW - dt.timedelta(minutes=args.quiet)
    sess = sessions(project_dir, args.hours)
    verdicts = []

    print(f"Agent health for {project_dir}")
    print(f"Checked at {stamp(NOW)}. Last wake from sleep: {stamp(wake)} ({ago(wake)})." if wake
          else f"Checked at {stamp(NOW)}. Last wake from sleep: unknown (no power log).")

    # Headless runs started in this folder.
    print("\nHeadless runs (claude -p) started in this folder:")
    headless = live_headless(project_dir, procs)
    if not headless:
        print("  none running")
    for p in headless:
        started = NOW - dt.timedelta(seconds=p["secs"])
        own = [s for s in sess if s["entry"] == "sdk-cli" and s["first"]
               and -10 <= (s["first"] - started).total_seconds() <= 180]
        s = own[0] if own else None
        wrote = max([t for t in ([s["last"], s["helper_last"]] if s else []) if t], default=None)
        kids = [k for k in descendants(p["pid"], procs) if not IDLE_CHILDREN.search(k["cmd"])]
        if wrote and wrote >= quiet_from:
            v = "WORKING"
        elif kids:
            v = "WAITING"
        elif wake and wake >= quiet_from:
            v = "JUST WOKE"
        else:
            v = "STALLED"
        verdicts.append(v)
        print(f"  pid {p['pid']}: {v}. Running {p['secs'] // 3600}h{(p['secs'] % 3600) // 60:02d}m; "
              f"last write by it or a helper {ago(wrote)} ({stamp(wrote)}).")
        if s:
            print(f"    transcript {s['id'][:8]}: own log {ago(s['last'])}, {s['helpers']} helper log(s), "
                  f"newest {ago(s['helper_last'])}")
        else:
            print("    transcript: not matched by start time (look under the project's encoded folder)")
        for k in kids[:5]:
            print(f"    child pid {k['pid']} cpu {k['cpu']:.1f}% up {k['secs'] // 60} min: {k['cmd'][:110]}")

    # Other sessions (interactive or background): their last write, and any background command they
    # started that has not reported back. Such a command is work in progress, so it counts as WAITING.
    print(f"\nSessions of this project written in the last {args.hours:g}h (newest first):")
    for s in sess[:8]:
        kind = "headless" if s["entry"] == "sdk-cli" else (s["entry"] or "?")
        print(f"  {s['id'][:8]} [{kind}]: last write {ago(s['last'])} ({stamp(s['last'])}); "
              f"{s['helpers']} helper log(s), newest {ago(s['helper_last'])}")
        for p in s.get("pending", []):
            print(f"    WAITING: background command {p['id']} \"{p['description'][:80]}\" "
                  f"started {ago(p['started'])}, has not reported back")
        if s.get("pending"):
            verdicts.append("WAITING")
    if not sess:
        print("  none")

    worst = next((v for v in ("STALLED", "JUST WOKE", "WAITING", "WORKING") if v in verdicts),
                 "NOTHING RUNNING")
    print(f"\nOVERALL: {worst}")
    if args.ping_when_done:
        print(arm(project_dir, procs, args.poll, args.max_hours) if headless
              else "PING NOT ARMED: no headless run is alive in this folder")
    return 1 if worst == "STALLED" else 0


if __name__ == "__main__":
    sys.exit(main())

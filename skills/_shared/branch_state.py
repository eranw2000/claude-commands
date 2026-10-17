#!/usr/bin/env python3
"""Report a repo's branch state without mixing up HEAD and the default branch.

`git rev-list --left-right --count HEAD...main` answers "where is the CHECKOUT
relative to main", and a briefing then reads it as "where is local main". When the
checkout sits on an old feature branch those are different questions with
different answers.
For example, a checkout on a merged branch 2 ahead / 32 behind main gets reported as
"local main is 2 ahead, 32 behind" while local main equals origin/main.

So this prints the three facts separately and names the branch each one is about:

    branch: <current branch, or DETACHED>
    default: <default branch>
    on_default: yes|no
    default_vs_remote: ahead=<n> behind=<n>      (local default vs origin/default)
    head_vs_default: ahead=<n> behind=<n>        (only when not on the default)
    summary: <one plain sentence>

Usage: branch_state.py [repo_path]. Read-only: never fetches, never switches.
Exit 0 on a report, 2 when the path is not a git repo.
"""
import subprocess
import sys


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def default_branch(repo):
    rc, out = git(repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
    if rc == 0 and out:
        return out.rsplit("/", 1)[-1]
    for name in ("main", "master"):
        if git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}")[0] == 0:
            return name
    return None


def ahead_behind(repo, left, right):
    rc, out = git(repo, "rev-list", "--left-right", "--count", f"{left}...{right}")
    if rc != 0 or not out:
        return None
    a, b = out.split()
    return int(a), int(b)


def report(repo):
    if git(repo, "rev-parse", "--git-dir")[0] != 0:
        return None
    rc, branch = git(repo, "branch", "--show-current")
    branch = branch or "DETACHED"
    default = default_branch(repo)
    lines = [f"branch: {branch}", f"default: {default or 'UNKNOWN'}"]
    if default is None:
        lines.append("summary: no default branch found, so nothing was compared")
        return lines
    on_default = branch == default
    lines.append(f"on_default: {'yes' if on_default else 'no'}")

    remote = f"origin/{default}"
    has_remote = git(repo, "rev-parse", "--verify", "--quiet", remote)[0] == 0
    dvr = ahead_behind(repo, default, remote) if has_remote else None
    lines.append("default_vs_remote: " + (f"ahead={dvr[0]} behind={dvr[1]}" if dvr
                                          else f"no {remote} to compare"))
    parts = []
    if dvr:
        parts.append(f"local {default} is {dvr[0]} ahead and {dvr[1]} behind {remote}"
                     if dvr != (0, 0) else f"local {default} equals {remote}")
    if not on_default:
        base = remote if has_remote else default
        hvd = ahead_behind(repo, "HEAD", base)
        if hvd:
            lines.append(f"head_vs_default: ahead={hvd[0]} behind={hvd[1]}")
            parts.insert(0, f"the checkout is on {branch}, NOT {default} "
                            f"({hvd[0]} ahead, {hvd[1]} behind {base})")
    lines.append("summary: " + "; ".join(parts) if parts else "summary: nothing to compare")
    return lines


def main(argv):
    repo = argv[1] if len(argv) > 1 else "."
    lines = report(repo)
    if lines is None:
        print(f"not a git repo: {repo}", file=sys.stderr)
        return 2
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

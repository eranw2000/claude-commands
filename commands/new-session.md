---
description: "Start-of-session briefing: this project's open TODO items, plus open action items not yet tracked in the TODO."
argument-hint: "[project name] (optional; defaults to the current directory's project)"
---

Give a fast read on where a project stands when you sit back down on it. Produce a single session-start briefing with two parts, in this order. This command is **read-only**: inspect and report, never commit, push, deploy, or edit files. The one allowed mutation is offered (not performed) at the very end: adding the uncaptured items to TODO.md, and only if you say yes.

If `$ARGUMENTS` names a project, orient on that one. Otherwise resolve from the current directory (see Setup).

(Context-window usage is shown continuously in the status line if you install the bundled `statusline.sh`, so this briefing does not cover it.)

## Setup: resolve the project (do this first)

Resolve in order, stop at the first hit:

1. If `$ARGUMENTS` is non-empty, treat it as the project name and match it under `~/.claude/projects/` by name: `find ~/.claude/projects -maxdepth 1 -type d -iname '*<arg>*'`. The data-dir folder name may not equal the repo name, so match by name rather than building the path.
2. Else if cwd is inside `~/.claude/projects/<X>/`: project = `<X>`.
3. Else if cwd is inside a git repo (`REPO_ROOT=$(git rev-parse --show-toplevel)`): take the repo basename, then match it against `~/.claude/projects/` by NAME with the same `find` as step 1 (the data-dir folder name frequently does NOT equal the repo name). Never string-build the project path and assume it exists.
4. Zero or multiple matches, or cwd is bare `~/.claude`: list `ls -lt ~/.claude/projects` (top 5) and ASK which project. Do not guess.

State the resolved project, the path to its `TODO.md` (`~/.claude/projects/<X>/TODO.md`), and its `CLAUDE.md` (repo-root first, then `~/.claude/projects/<X>/CLAUDE.md`) in one line. Also capture `REPO_ROOT` if a linked repo is found; Part 2's sweep needs it.

## Part 1: Open TODO items (this project)

Read `~/.claude/projects/<X>/TODO.md`. Render the **open** (unchecked `- [ ]`) items, grouped by the buckets the file actually uses (honor any non-canonical bucket labels or extra buckets a curated file has; render a pin block first if present). Lead with a one-line count summary (e.g. "3 active, 1 queued, 1 parked"). Skip struck/`- [x]` items.

Surface due dates against today's date: annotate `OVERDUE` if past, `due in Nd` if within 7 days. Recognize the `(due YYYY-MM-DD)` suffix and prose `Due YYYY-MM-DD` / `by YYYY-MM-DD` forms. The annotation is for display only; do not write it into the file.

If no `TODO.md` exists, say so.

## Part 2: Open action items NOT in the TODO list

Sweep the sources below for open/pending work, then **reconcile against Part 1**: drop anything already represented in `TODO.md` (substring or clear semantic match) and present only what is uncaptured. The goal is to catch loose ends the TODO doesn't know about. Run the read-only commands in parallel where possible; tolerate missing tools (skip a source silently if its tool/file is absent).

1. **Project CLAUDE.md**: scan for pending work in sections like "Still blocked", "Open questions", "Next steps", "Deferred", "TODO", and any gotcha that names an unresolved action. Pull the open ones.
2. **Project memory** (if you keep one): `~/.claude/projects/<index-dir>/memory/project_*.md` for this project, where `<index-dir>` is the dash-encoded home path (e.g. `-Users-jdoe` for `/Users/jdoe`; derive it from `$HOME`). Look for "awaiting", "blocked on", "pending", or unfinished-decision items. Skip if no memory folder exists.
3. **Git working state** (if `REPO_ROOT`): `git status --porcelain` (uncommitted/staged work in flight), `git rev-list --left-right --count HEAD...<default-branch>` (commits ahead means unpushed work), `git stash list` (forgotten stashes). Use the repo's actual default branch.
4. **Open PRs** (if `gh` is authed and a remote exists): `gh pr list --state open --json number,title,isDraft,createdAt`. Flag PRs older than 14 days as stale.
5. **Code markers** (optional, repo only): a count of `TODO`/`FIXME`/`XXX` markers via `grep -rInE '\b(TODO|FIXME|XXX)\b'` excluding `.venv`/`node_modules`/`.git`. Report the count, do not dump them, unless one obviously names a near-term action.

Present these under a clear heading like "Open, not tracked in TODO.md" with the source noted per item (e.g. `[PR #12]`, `[CLAUDE.md: Still blocked]`, `[git: 2 commits ahead]`). If everything open is already in the TODO, say so plainly.

## Output shape

Keep it scannable and short, one screen if possible:

1. Resolved project and file paths (one line).
2. **In TODO**: open items by bucket, with due-date flags.
3. **Open, not in TODO**: uncaptured items with source tags, or "nothing uncaptured".
4. A closing line: if Part 2 found uncaptured items, offer to add them to `TODO.md` (ask first; do not add unprompted). Otherwise suggest the single most sensible next action based on what you found.

Do not pad the briefing with restated CLAUDE.md detail; link or point rather than copy. Follow plain-prose conventions (no em dashes in your own prose, no box-drawing characters in any table).

# Claude Code commands

Two slash commands for Claude Code, plus a status-line script that shows your context-window usage continuously.

- **`/new-session`** — start-of-session briefing for a project: its open TODO items, plus open action items not yet tracked in the TODO (from CLAUDE.md, project memory, git state, open PRs, and code markers). Read-only.
- **`/instruct <file>`** — run an instruction file from `~/.claude/instructions/` (or a path): switches to Plan mode, resolves and reads the file, drafts a plan, and waits for your approval before executing.
- **`statusline.sh`** — prints e.g. `[Opus 4.8] 37% used · 63% left · 74k/200k` (model, context used and remaining percentage, tokens used vs capacity, and an `over 200k` flag when the context crosses the fixed 200k threshold) so your usage is always visible at the bottom of the terminal.

## Install

### Commands

Copy the command files into your Claude Code commands directory:

```bash
mkdir -p ~/.claude/commands
cp commands/*.md ~/.claude/commands/
```

They're available immediately as `/new-session` and `/instruct`.

### Status line

The status line replaces the old manual "run /context" step in `/new-session`: instead of asking, your context usage shows continuously.

1. Install `jq` if you don't have it (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu). The script uses it to parse the session JSON Claude Code pipes in.
2. Copy the script and make it executable:
   ```bash
   cp statusline.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```
3. Add this to `~/.claude/settings.json` (merge into your existing settings, don't overwrite the file):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline.sh"
     }
   }
   ```

Restart Claude Code (or start a new session) and you'll see something like `[Opus 4.8] 37% used · 63% left · 74k/200k` in the status line. The context fields can be null right after start or a `/compact`; the script falls back to `0` until the first API call populates them.

## Notes

- `/new-session` works best if you keep per-project notes under `~/.claude/projects/<X>/` (a `TODO.md` and an optional `CLAUDE.md` / `memory/` folder). It degrades gracefully when those don't exist: it just reports what it can find from git and open PRs. Paths are derived from `$HOME`, so it works on any machine without editing.
- `/instruct` expects instruction files in `~/.claude/instructions/`. Create that folder and drop `.md` files in it, then run `/instruct <name>`.
- The commands are read-only by design except for one explicit, confirmed action (`/new-session` may offer to append uncaptured items to your `TODO.md`, only after you say yes).

## License

MIT. See [LICENSE](LICENSE).

---
description: Perform the instructions contained in a named instruction file
argument-hint: <file_name> (a file in ~/.claude/instructions/, or a path)
---

Please perform the following instructions: **$ARGUMENTS**

**First, switch to Plan mode.** Before reading or doing anything else, call the `EnterPlanMode` tool so the rest of this command runs in Plan mode. Resolve the file, read it, draft a plan, and present that plan for approval (via `ExitPlanMode`) before executing any of it.

Resolve the instruction file before doing anything else:

1. Treat `$ARGUMENTS` as the name of an instruction file. The canonical location is `~/.claude/instructions/`.
2. Resolve it in this order, stopping at the first hit:
   - If `$ARGUMENTS` is an absolute or relative path that exists, use it as-is.
   - Otherwise look in `~/.claude/instructions/` for an exact match.
   - If no exact match, append `.md` and try again (`$ARGUMENTS.md`).
   - If still nothing, do a case-insensitive / fuzzy match against the files in `~/.claude/instructions/` (names can contain spaces and mixed case, e.g. `My Feature Spec.md`). Use `ls "$HOME/.claude/instructions/"` to see the options.
   - If exactly one file clearly matches, proceed with it. If several plausibly match, list the candidates and ask which one. If none match, say so and show the available instruction files.
3. Read the resolved file in full. Treat its contents as instructions given to you directly in this conversation, and apply the project's CLAUDE.md rules and your working preferences.
4. If the instruction file itself references other files, data, or sources, read those as needed to understand the full scope before planning.
5. Draft a concrete plan for carrying out the instructions end-to-end, then present it with `ExitPlanMode` for approval. Once approved, execute the plan end-to-end with full autonomy, don't stop to ask permission for steps that are clearly part of the approved plan.

Begin by entering Plan mode, then resolve and read the file, then present the plan.

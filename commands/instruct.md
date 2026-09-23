---
model: inherit
description: Perform an instruction, given as an instruction file, a file plus its argument, or a description typed in the CLI
argument-hint: <file_name> (a file in ~/.claude/instructions/, or a path) [argument the file expects] OR a description of the work, typed as a sentence or a paragraph
---
Please perform the following instructions: **$ARGUMENTS**

**First, switch to Plan mode.** Before reading or doing anything else, call the `EnterPlanMode` tool so the rest of this command runs in Plan mode. Resolve the file, read it, draft a plan, and present that plan for approval (via `ExitPlanMode`) before executing any of it.

**`$ARGUMENTS` comes in three forms, and step 2 decides which one you have.**

1. **A FILE.** A name in `~/.claude/instructions/`, or a path to any instruction or plan file.
2. **A FILE WITH SOMETHING ELSE.** Either the file first and its argument after it, or an intent phrase first with the path at the end.
3. **A DESCRIPTION.** A sentence or a paragraph typed straight into the CLI, describing the work itself, with no instruction file behind it at all.

The three converge after step 2: from step 3 onward a description IS what a file's contents would have been, and everything after it (the draft plan, Plan mode, the approval, the implementation) runs identically.

Resolve the instruction file before doing anything else:

1. Treat `$ARGUMENTS` as the name of an instruction file. The canonical location is `~/.claude/instructions/`.
2. Resolve it in this order, stopping at the first hit:
   - **An intent phrase resolves FIRST, ahead of every path test below.** `$ARGUMENTS` may describe what to DO rather than name an instruction file, and such a phrase normally ENDS with a path of its own. A path test reaches that path first and opens it as the instruction file, which is the wrong file, so match intent before any path rule runs. Match on meaning rather than on exact wording. If a phrase matches no intent, or plausibly matches more than one, fall through to the path rules below and resolve it there. Never invent a default. Add your own intents as further bullets here, each naming what the trailing path means for that intent.
   - If `$ARGUMENTS` is an absolute or relative path that exists, use it as-is.
   - If `$ARGUMENTS` STARTS with a path that exists and is followed by more text, use that path as the instruction file and treat the remaining text as ARGUMENTS TO IT. An instruction file may be written to take an argument (a plan path, a goal, a mode), so trailing text is that argument rather than part of the filename. Read the file, then apply it to the argument you were given; if the file expects an argument and none was supplied, ask for it rather than choosing one.
   - Otherwise look in `~/.claude/instructions/` for an exact match.
   - If no exact match, append `.md` and try again (`$ARGUMENTS.md`).
   - If still nothing, do a case-insensitive / fuzzy match against the files in `~/.claude/instructions/` (names can contain spaces and mixed case, e.g. `My Feature Spec.md`). Use `ls "$HOME/.claude/instructions/"` to see the options. **A fuzzy match counts only when the WHOLE of `$ARGUMENTS` reads as a file NAME**, meaning a short label of a few words that one filename covers almost entirely. One or two words shared between a sentence and a filename is NOT a match. This narrowing is what makes form 3 safe: without it, a description that happens to mention a spec or a feature gets run as an unrelated instruction file.
   - If exactly one file clearly matches, proceed with it. If several plausibly match, list the candidates and ask which one.
   - **Nothing matched, so `$ARGUMENTS` is itself the instruction. This is form 3.** Work gets typed straight into the CLI, so text that names no file and reads as WORK TO DO is an instruction rather than a failed lookup. Take it exactly as you would a one-paragraph instruction file, and run the whole normal path on it.
     - **Say so in one line before you start**, naming the work you are about to plan and the fact that no instruction file matched. It costs a sentence and it is the only chance to catch a wrong reading before a plan gets drafted.
     - **A path inside the text is CONTEXT, not the instruction file.** Read every file the description names, per step 4, then follow the description itself.
     - **It reads as work when it has a verb and an ask**, for example "add a rate limit to the login endpoint" or "work out why the nightly job stopped". A bare noun phrase with no verb, such as "the login spec" or "rate limiting", is a failed file lookup instead: say so and show the available instruction files, as before.
     - **Ambiguity stops and never guesses.** If the text both reads as work AND plausibly names a file, give both readings and ask which one. A wrong guess here runs an unrelated file's instructions against the words you were given.
3. Read the resolved file in full. **If it is empty or holds only whitespace, STOP**: name the file, say it is empty, and do nothing else. Do not fall through to a fuzzy match or to form 3, and do not start planning from the file's name, because an empty file carries no instruction to follow. Treat its contents as instructions given to you directly in this conversation, and apply the project's CLAUDE.md rules and your working preferences. **On form 3 there is no file to read**, because the typed text is already that content. Carry straight on to step 4 and treat those words exactly as you would a file's.
4. If the instruction file itself references other files, data, or sources, read those as needed to understand the full scope before planning.
5. Draft a concrete plan for carrying out the instructions end-to-end, then present it with `ExitPlanMode` for approval. **On form 3, plan against the typed words VERBATIM rather than against your paraphrase of them**, so the plan answers what was asked rather than your reading of it. Once approved, execute the plan end-to-end with full autonomy, don't stop to ask permission for steps that are clearly part of the approved plan.

Begin by entering Plan mode, then resolve `$ARGUMENTS`, read the instruction file if there is one, then present the plan.

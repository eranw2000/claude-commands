#!/bin/bash
# Claude Code status line.
# Shows: model, current directory + git branch, context used/remaining %
# ... plus optional badges naming a skill that just ran (configurable below).
# (color-coded green/yellow/red by fill level), tokens used vs capacity, and
# a token gauge: green actual count under 400k, yellow past 400k, red past 600k.
# Reads the statusLine JSON from stdin. Requires jq.
#
# Model display tracks the ACTUAL model, not just the session setting: the
# last assistant message in the transcript records which model produced it,
# so a per-turn override (a skill/command with `model:` frontmatter, e.g.
# /new-session pinning sonnet) shows up as [Fable 5→Sonnet 5] while it is
# active, and reverts to [Fable 5] on the next plain turn.
#
# Field paths (per the Claude Code statusLine schema):
#   .model.display_name
#   .transcript_path                        (session JSONL; assistant lines carry .message.model)
#   .workspace.current_dir                  (falls back to $PWD if absent)
#   .context_window.used_percentage         (may be null early in a session)
#   .context_window.remaining_percentage
#   .context_window.total_input_tokens
#   .context_window.context_window_size     (default 200000; 1000000 for extended-context models)
#
# Tunables:
OVER_YELLOW=400000 # in-window token count above which a yellow "over" flag shows
OVER_RED=600000    # in-window token count above which the "over" flag turns red
YELLOW_PCT=40      # used % at/above which the context indicator turns yellow
RED_PCT=61         # used % at/above which it turns red

input=$(cat)

MODEL=$(echo "$input"   | jq -r '.model.display_name // "?"')
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // empty')
DIR=$(echo "$input"     | jq -r '.workspace.current_dir // empty')
[ -z "$DIR" ] && DIR=$PWD
USED=$(echo "$input"    | jq -r '.context_window.used_percentage // 0'          | cut -d. -f1)
REMAIN=$(echo "$input"  | jq -r '.context_window.remaining_percentage // empty' | cut -d. -f1)
[ -z "$REMAIN" ] && REMAIN=$((100 - USED))
TOKENS=$(echo "$input"  | jq -r '.context_window.total_input_tokens // 0'       | cut -d. -f1)
SIZE=$(echo "$input"    | jq -r '.context_window.context_window_size // 200000' | cut -d. -f1)

# Actual model of the LAST assistant reply, from the transcript. A per-turn
# model override (skill/command `model:` frontmatter) changes .message.model
# there while .model.display_name keeps the session setting.
pretty_model() {
  case "$1" in
    claude-fable-5*)   echo "Fable 5"   ;;
    claude-opus-5*)    echo "Opus 5"    ;;
    claude-sonnet-5*)  echo "Sonnet 5"  ;;
    claude-opus-4-8*)  echo "Opus 4.8"  ;;
    claude-opus-4-7*)  echo "Opus 4.7"  ;;
    claude-haiku-4-5*) echo "Haiku 4.5" ;;
    *)                 echo "$1"        ;;
  esac
}

MODEL_DISPLAY="$MODEL"
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # tail keeps this cheap on long sessions; a mid-write partial last line only
  # drops itself (jq already emitted the earlier matches by then).
  ACTUAL_ID=$(tail -n 200 "$TRANSCRIPT" 2>/dev/null \
    | jq -r 'select(.type=="assistant" and .isSidechain != true
                    and (.message.model // "") != "" and .message.model != "<synthetic>")
             | .message.model' 2>/dev/null | tail -n 1)
  if [ -n "$ACTUAL_ID" ]; then
    ACTUAL=$(pretty_model "$ACTUAL_ID")
    # Show the override arrow only when the actual model isn't the session one
    # (substring match tolerates display names like "Fable 5 (1M context)").
    case "$(echo "$MODEL" | tr '[:upper:]' '[:lower:]')" in
      *"$(echo "$ACTUAL" | tr '[:upper:]' '[:lower:]')"*) MODEL_DISPLAY="$MODEL" ;;
      *) MODEL_DISPLAY="${MODEL}→${ACTUAL}" ;;
    esac
  fi
fi

# Current directory basename + git branch (computed locally; branch omitted if not a repo)
BASE=$(basename "$DIR")
BRANCH=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
LOC="$BASE"
[ -n "$BRANCH" ] && LOC="$BASE ($BRANCH)"

# Color the context indicator by how full the window is
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
if   [ "$USED" -ge "$RED_PCT" ];    then C=$RED
elif [ "$USED" -ge "$YELLOW_PCT" ]; then C=$YELLOW
else                                     C=$GREEN
fi

# Compact token formatter: 15500 -> 16K, 1000000 -> 1M, 1500000 -> 1.5M
fmt() {
  local n=${1:-0}
  if [ "$n" -ge 1000000 ]; then
    local m
    m=$(awk "BEGIN{printf \"%.1f\", $n/1000000}")
    m=${m%.0}
    printf '%sM' "$m"
  else
    printf '%dK' $(( (n + 500) / 1000 ))
  fi
}

# --- Skill badges ------------------------------------------------------------
# Two optional badges naming a skill that just ran. Each says its skill is what
# happened LAST, so each is withdrawn as soon as the session produces something
# that skill did not capture, and running it again brings it back.
#
# Configure them here. Each list is space-separated skill or slash-command names
# exactly as you invoke them. An empty list disables that badge.
BADGE_A_SKILLS="save-context close-session"
BADGE_A_LABEL="Session Saved"
BADGE_B_SKILLS=""
BADGE_B_LABEL="Workflow Improved"
#
# Each badge tracks three byte offsets: where its skill was invoked, where that
# turn ended, and where it was invalidated. It shows while the first is set and
# the third is not. After the invocation, any of these invalidate it:
#   - something fed INTO the session: a typed prompt, a slash command, or a
#     background task notification. These are user entries whose content is a
#     plain string. A tool result has list content, so a run never invalidates
#     itself through its own steps.
#   - another skill being invoked. This is the case a new prompt cannot catch,
#     because a long run can invoke a skill and then carry on inside the SAME
#     turn with nobody typing anything.
#   - any conversation entry after that turn ended. The report a skill prints is
#     the end of its own turn, so it does not invalidate its own badge.
#
# Two exemptions, both measured over real transcripts, because each is a case
# where the plain rule withdraws a badge during the very run that raised it:
#   - a run spawning an AGENT or a task is doing its own work. 10 of 31 measured
#     runs of one long skill spawned one inside their own turn, so without this
#     the badge died on almost every real run.
#   - a run invoking the OTHER badge's skill as one of its own steps. Measured at
#     13 times across 424 runs of one skill that calls another.
# Both lapse once the turn has ended, after which everything counts. If you would
# rather a spawned agent DID withdraw a badge, delete the "return" on the
# is-not-a-skill line in rule 3.
#
# Turn end is read from "stop_reason":"end_turn", never inferred from a line
# having no tool call: text, thinking and tool_use each land on their OWN line,
# so 138 of 220 measured lines carrying no tool call were mid-turn. One reply can
# also END on several lines, so the mark keeps moving forward instead of treating
# the second half of a report as work that came after it.
#
# Every pattern needs an unescaped double quote. That is what separates a real
# invocation from the same text quoted back inside a tool result, where JSON
# escaping turns each inner quote into \". isMeta entries are excluded, because
# image size notes, the local-command caveat and Stop-hook feedback all arrive as
# string content and none of them is the session moving on.
#
# A full scan of a large transcript costs about a fifth of a second and would be
# paid on every redraw, so state is cached per session and each redraw seeks
# straight to the bytes appended since the last one. Only COMPLETE lines are
# consumed, so a redraw landing mid-write re-reads that line next time instead of
# losing it. LC_ALL=C keeps awk length() in bytes, which the offsets depend on.
STATE_DIR="$HOME/.claude/.statusline-state"
STATE_VERSION=v2

BADGE_A=""; BADGE_B=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && [ -n "$BADGE_A_SKILLS$BADGE_B_SKILLS" ]; then
  STATE="$STATE_DIR/$(basename "$TRANSCRIPT" .jsonl)"
  VER=""; OFF=0; AP=0; AFIN=0; ABAD=0; BP=0; BFIN=0; BBAD=0
  if [ -f "$STATE" ]; then
    { read -r VER; read -r OFF; read -r AP; read -r AFIN; read -r ABAD
      read -r BP; read -r BFIN; read -r BBAD; } < "$STATE"
  else
    mkdir -p "$STATE_DIR" 2>/dev/null
    # once per session: drop state left behind by sessions long gone
    find "$STATE_DIR" -type f -mtime +14 -delete 2>/dev/null
  fi
  # an older format holds different fields in these slots, so rescan instead
  [ "$VER" = "$STATE_VERSION" ] || { OFF=0; AP=0; AFIN=0; ABAD=0; BP=0; BFIN=0; BBAD=0; }
  for v in OFF AP AFIN ABAD BP BFIN BBAD; do
    eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
  done

  SZ=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')
  case "$SZ" in ''|*[!0-9]*) SZ=0 ;; esac
  # a shorter file is a different file: start over rather than trust old offsets
  [ "$OFF" -gt "$SZ" ] && { OFF=0; AP=0; AFIN=0; ABAD=0; BP=0; BFIN=0; BBAD=0; }

  if [ "$SZ" -gt "$OFF" ]; then
    COMPLETE=0; [ -z "$(tail -c 1 "$TRANSCRIPT")" ] && COMPLETE=1
    RES=$(tail -c "+$((OFF + 1))" "$TRANSCRIPT" 2>/dev/null | LC_ALL=C awk \
      -v pos="$OFF" -v complete="$COMPLETE" \
      -v alist="$BADGE_A_SKILLS" -v blist="$BADGE_B_SKILLS" \
      -v ap="$AP" -v afin="$AFIN" -v abad="$ABAD" \
      -v bp="$BP" -v bfin="$BFIN" -v bbad="$BBAD" '
      BEGIN { at["a"]=ap; fin["a"]=afin; bad["a"]=abad; names["a"]=alist
              at["b"]=bp; fin["b"]=bfin; bad["b"]=bbad; names["b"]=blist }

      # does this line invoke any skill in the given space-separated list?
      function raises(L, list,   n, i, w) {
        n = split(list, w, " ")
        for (i = 1; i <= n; i++) {
          if (w[i] == "") continue
          if (index(L, "<command-name>/" w[i] "</command-name>\"")) return 1
          if (index(L, "{\"skill\":\"" w[i] "\"")) return 1
        }
        return 0
      }

      function track(k, L, P,   isskill, other) {
        # 1. this badge being raised: a fresh reference point
        if (names[k] != "" && raises(L, names[k])) {
          at[k] = P; fin[k] = 0; bad[k] = 0; return
        }
        if (at[k] == 0 || bad[k] > 0) return
        # 2. something fed into the session
        if (index(L, "\"role\":\"user\",\"content\":\"") && !index(L, "\"isMeta\":true")) {
          bad[k] = P; return
        }
        # 3. another skill, agent or task. Two exemptions while the turn is open
        isskill = index(L, "\"name\":\"Skill\",\"input\":")
        if (isskill || index(L, "\"name\":\"Task\",\"input\":") ||
            index(L, "\"name\":\"Agent\",\"input\":")) {
          if (fin[k] > 0) { bad[k] = P; return }
          if (!isskill) return
          other = (k == "a") ? names["b"] : names["a"]
          if (other != "" && raises(L, other)) return
          bad[k] = P; return
        }
        # 4. the turn ending. Keep moving the mark: one reply can end on several
        #    lines, since thinking and text are separate lines that BOTH carry it
        if (index(L, "\"stop_reason\":\"end_turn\"")) { fin[k] = P; return }
        # 5. any conversation entry after that turn ended
        if (fin[k] > 0 && !index(L, "\"isMeta\":true") &&
            (index(L, "\"type\":\"assistant\"") || index(L, "\"type\":\"user\""))) {
          bad[k] = P; return
        }
      }
      function classify(L, P) { track("a", L, P); track("b", L, P) }
      # one-record delay: a line is only known complete once another follows it
      { if (have) classify(prev, prevpos); prev = $0; prevpos = pos; have = 1; pos += length($0) + 1 }
      END {
        if (have && complete) classify(prev, prevpos)
        else if (have) pos = prevpos
        print pos
        print at["a"]; print fin["a"]; print bad["a"]
        print at["b"]; print fin["b"]; print bad["b"]
      }')
    { read -r OFF; read -r AP; read -r AFIN; read -r ABAD
      read -r BP; read -r BFIN; read -r BBAD; } <<< "$RES"
    for v in OFF AP AFIN ABAD BP BFIN BBAD; do
      eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
    done
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$STATE_VERSION" \
      "$OFF" "$AP" "$AFIN" "$ABAD" "$BP" "$BFIN" "$BBAD" > "$STATE" 2>/dev/null
  fi

  [ "$AP" -gt 0 ] && [ "$ABAD" -eq 0 ] && BADGE_A=1
  [ "$BP" -gt 0 ] && [ "$BBAD" -eq 0 ] && BADGE_B=1
fi

# The actual token count shows green while under 400k; past 400k a yellow
# "over 400K" flag appears, past 600k a red "over 600K".
if [ "$TOKENS" -gt "$OVER_YELLOW" ]; then GAUGE=""; GAUGE_R=""; else GAUGE=$GREEN; GAUGE_R=$RESET; fi
LINE="[$MODEL_DISPLAY] ${LOC} · ${C}${USED}% used · ${REMAIN}% left${RESET} · ${GAUGE}$(fmt "$TOKENS")${GAUGE_R}/$(fmt "$SIZE")"
if   [ "$TOKENS" -gt "$OVER_RED" ];    then LINE="$LINE · ${RED}over $(fmt "$OVER_RED")${RESET}"
elif [ "$TOKENS" -gt "$OVER_YELLOW" ]; then LINE="$LINE · ${YELLOW}over $(fmt "$OVER_YELLOW")${RESET}"
fi
BOLDBLUE=$'\033[1;34m'
[ -n "$BADGE_A" ] && LINE="$LINE · ${BOLDBLUE}${BADGE_A_LABEL}${RESET}"
[ -n "$BADGE_B" ] && LINE="$LINE · ${BOLDBLUE}${BADGE_B_LABEL}${RESET}"
echo "$LINE"

#!/bin/bash
# Claude Code status line.
# Shows: model, current directory + git branch, context used/remaining %
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

# The actual token count shows green while under 400k; past 400k a yellow
# "over 400K" flag appears, past 600k a red "over 600K".
if [ "$TOKENS" -gt "$OVER_YELLOW" ]; then GAUGE=""; GAUGE_R=""; else GAUGE=$GREEN; GAUGE_R=$RESET; fi
LINE="[$MODEL_DISPLAY] ${LOC} · ${C}${USED}% used · ${REMAIN}% left${RESET} · ${GAUGE}$(fmt "$TOKENS")${GAUGE_R}/$(fmt "$SIZE")"
if   [ "$TOKENS" -gt "$OVER_RED" ];    then LINE="$LINE · ${RED}over $(fmt "$OVER_RED")${RESET}"
elif [ "$TOKENS" -gt "$OVER_YELLOW" ]; then LINE="$LINE · ${YELLOW}over $(fmt "$OVER_YELLOW")${RESET}"
fi
echo "$LINE"

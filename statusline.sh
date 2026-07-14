#!/bin/bash
# Claude Code status line.
# Shows: model, current directory + git branch, context used/remaining %
# (color-coded green/yellow/red by fill level), tokens used vs capacity, and
# a token gauge: green actual count under 400k, yellow past 400k, red past 600k.
# Reads the statusLine JSON from stdin. Requires jq.
#
# Field paths (per the Claude Code statusLine schema):
#   .model.display_name
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
DIR=$(echo "$input"     | jq -r '.workspace.current_dir // empty')
[ -z "$DIR" ] && DIR=$PWD
USED=$(echo "$input"    | jq -r '.context_window.used_percentage // 0'          | cut -d. -f1)
REMAIN=$(echo "$input"  | jq -r '.context_window.remaining_percentage // empty' | cut -d. -f1)
[ -z "$REMAIN" ] && REMAIN=$((100 - USED))
TOKENS=$(echo "$input"  | jq -r '.context_window.total_input_tokens // 0'       | cut -d. -f1)
SIZE=$(echo "$input"    | jq -r '.context_window.context_window_size // 200000' | cut -d. -f1)

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

# Compact token formatter: 15500 -> 16k, 1000000 -> 1M, 1500000 -> 1.5M
fmt() {
  local n=${1:-0}
  if [ "$n" -ge 1000000 ]; then
    local m
    m=$(awk "BEGIN{printf \"%.1f\", $n/1000000}")
    m=${m%.0}
    printf '%sM' "$m"
  else
    printf '%dk' $(( (n + 500) / 1000 ))
  fi
}

# The actual token count shows green while under 400k; past 400k a yellow
# "over 400k" flag appears, past 600k a red "over 600k".
if [ "$TOKENS" -gt "$OVER_YELLOW" ]; then GAUGE=""; GAUGE_R=""; else GAUGE=$GREEN; GAUGE_R=$RESET; fi
LINE="[$MODEL] ${LOC} · ${C}${USED}% used · ${REMAIN}% left${RESET} · ${GAUGE}$(fmt "$TOKENS")${GAUGE_R}/$(fmt "$SIZE")"
if   [ "$TOKENS" -gt "$OVER_RED" ];    then LINE="$LINE · ${RED}over $(fmt "$OVER_RED")${RESET}"
elif [ "$TOKENS" -gt "$OVER_YELLOW" ]; then LINE="$LINE · ${YELLOW}over $(fmt "$OVER_YELLOW")${RESET}"
fi
echo "$LINE"

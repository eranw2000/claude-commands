#!/bin/bash
# Claude Code status line.
# Shows: model, context used/remaining %, tokens used vs capacity, and an
# "over 200k" flag when the context crosses the fixed 200k threshold.
# Reads the statusLine JSON from stdin. Requires jq.
#
# Field paths (per the Claude Code statusLine schema):
#   .model.display_name
#   .context_window.used_percentage        (may be null early in a session)
#   .context_window.remaining_percentage
#   .context_window.total_input_tokens
#   .context_window.context_window_size    (default 200000; 1000000 for extended-context models)
#   .exceeds_200k_tokens                    (TOP LEVEL, boolean)

input=$(cat)

MODEL=$(echo "$input"   | jq -r '.model.display_name // "?"')
USED=$(echo "$input"    | jq -r '.context_window.used_percentage // 0'      | cut -d. -f1)
REMAIN=$(echo "$input"  | jq -r '.context_window.remaining_percentage // empty' | cut -d. -f1)
[ -z "$REMAIN" ] && REMAIN=$((100 - USED))
TOKENS=$(echo "$input"  | jq -r '.context_window.total_input_tokens // 0'   | cut -d. -f1)
SIZE=$(echo "$input"    | jq -r '.context_window.context_window_size // 200000' | cut -d. -f1)
EXCEEDS=$(echo "$input" | jq -r '.exceeds_200k_tokens // false')

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

LINE="[$MODEL] ${USED}% used · ${REMAIN}% left · $(fmt "$TOKENS")/$(fmt "$SIZE")"
[ "$EXCEEDS" = "true" ] && LINE="$LINE · over 200k"
echo "$LINE"

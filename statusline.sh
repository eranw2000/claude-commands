#!/bin/bash
# Claude Code status line.
# Shows: model, context used/remaining %, tokens used vs capacity, and an
# "over 300k" flag when the in-window token count crosses 300k.
# Reads the statusLine JSON from stdin. Requires jq.
#
# Field paths (per the Claude Code statusLine schema):
#   .model.display_name
#   .context_window.used_percentage        (may be null early in a session)
#   .context_window.remaining_percentage
#   .context_window.total_input_tokens
#   .context_window.context_window_size    (default 200000; 1000000 for extended-context models)
#
# The flag is computed from total_input_tokens, not the built-in
# .exceeds_200k_tokens field, because that field is hard-coded to a 200k
# threshold. Change THRESHOLD below to retarget it.

THRESHOLD=300000

input=$(cat)

MODEL=$(echo "$input"   | jq -r '.model.display_name // "?"')
USED=$(echo "$input"    | jq -r '.context_window.used_percentage // 0'      | cut -d. -f1)
REMAIN=$(echo "$input"  | jq -r '.context_window.remaining_percentage // empty' | cut -d. -f1)
[ -z "$REMAIN" ] && REMAIN=$((100 - USED))
TOKENS=$(echo "$input"  | jq -r '.context_window.total_input_tokens // 0'   | cut -d. -f1)
SIZE=$(echo "$input"    | jq -r '.context_window.context_window_size // 200000' | cut -d. -f1)

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
[ "$TOKENS" -gt "$THRESHOLD" ] && LINE="$LINE · over $(fmt "$THRESHOLD")"
echo "$LINE"

#!/bin/sh
# One-shot backfill of `last_summary` into existing session state files.
#
# The hook only writes last_summary when an event fires, so sessions that
# were already sitting idle when the field was introduced would show an
# empty hover bubble until they moved again. This script finds each such
# session's transcript under ~/.claude/projects/*/<session_id>.jsonl and
# injects a summary using the same extraction as otter-hook.sh.
#
# Safe to re-run: files that already have a non-empty last_summary are
# skipped, and writes are atomic (tmp + mv), same as the hook.

JQ_BIN="/usr/bin/jq"
STATE_DIR="${OTTER_STATE_DIR:-$HOME/.local/state/notch-otter/sessions}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

[ -d "$STATE_DIR" ] || exit 0

for state_file in "$STATE_DIR"/*.json; do
  [ -f "$state_file" ] || continue

  existing=$("$JQ_BIN" -r '.last_summary // empty' "$state_file" 2>/dev/null)
  [ -n "$existing" ] && continue

  sid=$("$JQ_BIN" -r '.session_id // empty' "$state_file" 2>/dev/null)
  [ -z "$sid" ] && continue

  transcript=$(ls "$PROJECTS_DIR"/*/"$sid".jsonl 2>/dev/null | head -n 1)
  [ -f "$transcript" ] || continue

  # Keep in sync with the extraction in otter-hook.sh.
  summary=$(tail -n 60 "$transcript" 2>/dev/null | "$JQ_BIN" -rRs '
    split("\n")
    | map(fromjson? | select(.type == "assistant"))
    | map([.message.content[]? | select(.type == "text") | .text] | join(" "))
    | map(select(. != ""))
    | last // empty
    | gsub("```[\\s\\S]*?```"; " ")
    | gsub("\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)")
    | gsub("[*_#`~]"; "")
    | gsub("\\s+"; " ")
    | gsub("^\\s+|\\s+$"; "")
    | . as $t
    | [scan("[^.!?]+[.!?]*")] as $s
    | (if ($t | length) <= 200 then $t
       elif ($s | length) >= 2 then
         (($s[0] | gsub("^\\s+|\\s+$"; "")) + " … " + ($s[-1] | gsub("^\\s+|\\s+$"; "")))
       else $t end)
    | .[0:200]
  ' 2>/dev/null)
  [ -z "$summary" ] && continue

  tmp_file="$state_file.tmp.$$"
  if "$JQ_BIN" -c --arg s "$summary" '. + { last_summary: $s }' "$state_file" > "$tmp_file" 2>/dev/null; then
    mv -f "$tmp_file" "$state_file" 2>/dev/null
    echo "backfilled: $(basename "$state_file")"
  else
    rm -f "$tmp_file" 2>/dev/null
  fi
done

exit 0

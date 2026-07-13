#!/bin/sh
# NotchOtter hook dispatcher.
#
# Reads a single Claude Code hook JSON payload from stdin and updates the
# per-session state file described in SPEC.md section 1. This script is
# registered for every hook event NotchOtter cares about and branches on
# hook_event_name internally.
#
# Contract: this script must NEVER exit nonzero and must NEVER write to
# stderr during normal operation, even on malformed input. Any failure just
# means the state file is left as-is (or untouched) and we exit 0.

JQ_BIN="/usr/bin/jq"
STATE_DIR="${OTTER_STATE_DIR:-$HOME/.local/state/notch-otter/sessions}"

hook_json=$(cat 2>/dev/null)
if [ -z "$hook_json" ]; then
  exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null

session_id=$(printf '%s' "$hook_json" | "$JQ_BIN" -r '.session_id // empty' 2>/dev/null)
if [ -z "$session_id" ]; then
  exit 0
fi

state_file="$STATE_DIR/$session_id.json"
tmp_file="$state_file.tmp.$$"

if [ -f "$state_file" ]; then
  existing_json=$(cat "$state_file" 2>/dev/null)
  if [ -z "$existing_json" ]; then
    existing_json='{}'
  fi
else
  existing_json='{}'
fi

# $PPID is the pid of the process that spawned this script, i.e. the claude
# process itself (per SPEC.md: "hook runs as child of claude").
ppid_val="${PPID:-0}"

# last_summary: a short single-line excerpt of the most recent assistant
# reply, shown in the desktop pet's hover bubble. Prefer the Notification
# payload's own message (it names the pending tool for permission prompts);
# otherwise pull the last assistant text block from the transcript tail.
# Truncation happens in jq (codepoint-safe for Korean), NOT via cut -c
# (bytes), which could split a UTF-8 sequence and corrupt the state file.
summary=$(printf '%s' "$hook_json" | "$JQ_BIN" -r '
  if (.hook_event_name // "") == "Notification" and ((.message // "") != "")
  then .message else empty end
  | gsub("\\s+"; " ") | .[0:160]
' 2>/dev/null)
if [ -z "$summary" ]; then
  transcript_path=$(printf '%s' "$hook_json" | "$JQ_BIN" -r '.transcript_path // empty' 2>/dev/null)
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    # Last assistant entry that actually HAS text -- during tool-call bursts
    # the newest assistant entries are often tool_use-only (no text blocks),
    # and those must not blank out the summary. The text is then cleaned
    # (code fences, markdown glyphs, links) and condensed: replies lead with
    # the outcome and end with the next step / question, so when the whole
    # reply doesn't fit, "first sentence … last sentence" beats a mid-word
    # cut at some fixed offset.
    summary=$(tail -n 60 "$transcript_path" 2>/dev/null | "$JQ_BIN" -rRs '
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
  fi
fi

# tty is backfilled once per session, same as pid: only shell out to ps when
# the existing state file doesn't already have a non-empty tty, so the
# (relatively expensive) ps call happens at most once per session lifetime.
existing_tty=$(printf '%s' "$existing_json" | "$JQ_BIN" -r '.tty // empty' 2>/dev/null)
new_tty=""
if [ -z "$existing_tty" ]; then
  new_tty=$(ps -o tty= -p "$ppid_val" 2>/dev/null | tr -d ' ')
  case "$new_tty" in
    '??'|'?') new_tty="" ;;
  esac
fi

merged=$(printf '%s' "$hook_json" | "$JQ_BIN" -c \
  --argjson existing "$existing_json" \
  --arg pid "$ppid_val" \
  --arg new_tty "$new_tty" \
  --arg summary "$summary" \
  '
  . as $in
  | ($in.hook_event_name // "") as $event
  | ($in.cwd // $existing.cwd // "") as $cwd
  | ($cwd | rtrimstr("/")) as $cwd_trimmed
  | (($cwd_trimmed | split("/") | last) // "") as $project0
  | (if ($project0 // "") == "" then "unknown" else $project0 end) as $project
  | ($in.session_id // $existing.session_id // "") as $sid
  | (now | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")) as $ts
  | ($existing.error_count // 0) as $prev_err
  | ($existing.outputs // []) as $prev_outputs
  # launch_cwd is captured once from the first event that creates the state
  # file and never overwritten afterward, even as cwd itself keeps changing.
  | (($existing.launch_cwd // "") ) as $prev_launch_cwd
  | (if $prev_launch_cwd != "" then $prev_launch_cwd else $cwd end) as $launch_cwd
  | (($existing.tty // "")) as $prev_tty
  | (if $prev_tty != "" then $prev_tty else $new_tty end) as $tty_final
  | (
      if $event == "SessionStart" then
        {
          state: "idle",
          pid: (($pid | tonumber?) // ($existing.pid // 0)),
          outputs: [],
          error_count: 0
        }
      elif $event == "UserPromptSubmit" or $event == "PreToolUse" then
        { state: "working" }
      elif $event == "PostToolUse" then
        ((($in.tool_name // "") == "Write") or (($in.tool_name // "") == "Edit")) as $is_output_tool
        | ($in.tool_input.file_path // "") as $fp
        | (
            if $is_output_tool and ($fp != "") then
              (if ($prev_outputs | index($fp)) then $prev_outputs else ($prev_outputs + [$fp]) end)
            else
              $prev_outputs
            end
          ) as $merged_outputs
        | ($merged_outputs | if length > 200 then .[-200:] else . end) as $capped
        | { state: "working", error_count: 0, outputs: $capped }
      elif $event == "PostToolUseFailure" then
        ($prev_err + 1) as $newerr
        | { state: (if $newerr >= 3 then "error" else "working" end), error_count: $newerr }
      elif $event == "Notification" then
        (
          if $in.notification_type == "permission_prompt" then "waiting_permission"
          elif $in.notification_type == "idle_prompt" then "waiting_input"
          else ($existing.state // "working")
          end
        ) as $st
        | { state: $st }
      elif $event == "Stop" then
        { state: "done" }
      elif $event == "SessionEnd" then
        { _delete: true }
      else
        {}
      end
    ) as $delta
  | (
      $existing
      * { session_id: $sid, cwd: $cwd, project: $project, updated_at: $ts, last_event: $event,
          # Sessions started before install never fire SessionStart, so capture
          # the claude pid on whatever event arrives first.
          pid: (if (($existing.pid // 0) | tonumber? // 0) > 0 then $existing.pid else (($pid | tonumber?) // 0) end),
          launch_cwd: $launch_cwd }
      * (if $tty_final != "" then { tty: $tty_final } else {} end)
      * (if $summary != "" then { last_summary: $summary } else {} end)
      * $delta
    )
  ' 2>/dev/null)
status=$?

if [ $status -ne 0 ] || [ -z "$merged" ]; then
  exit 0
fi

case "$merged" in
  *'"_delete":true'*)
    rm -f "$state_file" "$tmp_file" 2>/dev/null
    ;;
  *)
    printf '%s\n' "$merged" > "$tmp_file" 2>/dev/null && mv -f "$tmp_file" "$state_file" 2>/dev/null
    ;;
esac

exit 0

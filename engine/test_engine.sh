#!/bin/sh
# Self-contained test suite for the NotchOtter engine scripts.
# Exercises otter-hook.sh for every hook event, and install.sh/uninstall.sh
# round-tripping against a fixture settings.json. Never touches real
# ~/.claude/settings.json or ~/.local files: everything runs in a temp dir.

set -u

JQ_BIN="/usr/bin/jq"
ENGINE_DIR=$(cd "$(dirname "$0")" && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/notch-otter-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

# Snapshot real ~/.claude files up front so Section C can assert the test run
# itself changed nothing (the engine may legitimately already be installed).
real_claude_fingerprint() {
  for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.pre-otter.bak"; do
    if [ -f "$f" ]; then
      md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | cut -d' ' -f1
    else
      echo "absent"
    fi
  done
}
REAL_CLAUDE_BEFORE=$(real_claude_fingerprint)

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1"
}

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected [$2], got [$3])"
  fi
}

# assert_true LABEL CONDITION_DESC ACTUAL_BOOL(0/1)
assert_true() {
  if [ "$2" = "1" ]; then
    pass "$1"
  else
    fail "$1"
  fi
}

state_field() {
  # state_field STATE_FILE JQ_EXPR
  "$JQ_BIN" -r "$2" "$1" 2>/dev/null
}

run_hook() {
  # run_hook STATE_DIR JSON_PAYLOAD
  OTTER_STATE_DIR="$1" "$ENGINE_DIR/otter-hook.sh" <<EOF
$2
EOF
}

echo "== Section A: otter-hook.sh event-by-event state machine =="

STATE_DIR="$TMP_ROOT/state"
SESSION_ID="test-session-1"
FAKE_CWD="/tmp/fake-project-otter-test"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"

mkdir -p "$FAKE_CWD"

# --- SessionStart ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "SessionStart", source: "startup", transcript_path: "/tmp/t.jsonl"}')"

hook_exit=$?
assert_eq "otter-hook.sh exits 0 on SessionStart" "0" "$hook_exit"
assert_true "state file created on SessionStart" "$( [ -f "$STATE_FILE" ] && echo 1 || echo 0 )"

state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "SessionStart -> state idle" "idle" "$state_val"

project_val=$(state_field "$STATE_FILE" '.project')
assert_eq "SessionStart -> project derived from cwd" "fake-project-otter-test" "$project_val"

pid_val=$(state_field "$STATE_FILE" '.pid')
# otter-hook.sh is a direct child of this test script, so its PPID == our own $$.
assert_eq "SessionStart -> pid captured via \$PPID" "$$" "$pid_val"

outputs_len=$(state_field "$STATE_FILE" '.outputs | length')
assert_eq "SessionStart -> outputs empty" "0" "$outputs_len"

err_val=$(state_field "$STATE_FILE" '.error_count')
assert_eq "SessionStart -> error_count 0" "0" "$err_val"

launch_cwd_val=$(state_field "$STATE_FILE" '.launch_cwd')
assert_eq "SessionStart -> launch_cwd set to initial cwd" "$FAKE_CWD" "$launch_cwd_val"

expected_tty=$(ps -o tty= -p "$$" 2>/dev/null | tr -d ' ')
case "$expected_tty" in
  '??'|'?') expected_tty="" ;;
esac
tty_val=$(state_field "$STATE_FILE" '.tty // ""')
assert_eq "SessionStart -> tty captured via ps -o tty= -p \$PPID" "$expected_tty" "$tty_val"

# --- Simulate an internal cd: cwd should update, launch_cwd must NOT ---
DIFFERENT_CWD="/tmp/fake-project-otter-test-after-cd"
mkdir -p "$DIFFERENT_CWD"
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$DIFFERENT_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "cd elsewhere"}}')"
cwd_val=$(state_field "$STATE_FILE" '.cwd')
launch_cwd_val=$(state_field "$STATE_FILE" '.launch_cwd')
assert_eq "cwd updates after simulated internal cd" "$DIFFERENT_CWD" "$cwd_val"
assert_eq "launch_cwd stays frozen at original launch dir after cwd changes" "$FAKE_CWD" "$launch_cwd_val"

tty_val=$(state_field "$STATE_FILE" '.tty // ""')
assert_eq "tty stays unchanged across a later event (not re-queried away)" "$expected_tty" "$tty_val"

# --- UserPromptSubmit ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "do the thing"}')"
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "UserPromptSubmit -> state working" "working" "$state_val"

# --- PreToolUse ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "echo hi"}}')"
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "PreToolUse -> state working" "working" "$state_val"

# --- PostToolUse (Write) ---
OUT1="$FAKE_CWD/output1.txt"
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" --arg fp "$OUT1" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUse", tool_name: "Write", tool_input: {file_path: $fp, content: "hi"}, tool_response: {success: true}}')"
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "PostToolUse(Write) -> state working" "working" "$state_val"
has_output=$("$JQ_BIN" -r --arg fp "$OUT1" '.outputs | index($fp) != null' "$STATE_FILE")
assert_eq "PostToolUse(Write) -> outputs contains file_path" "true" "$has_output"
err_val=$(state_field "$STATE_FILE" '.error_count')
assert_eq "PostToolUse(Write) -> error_count reset to 0" "0" "$err_val"

# --- PostToolUse duplicate Write (dedup check) ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" --arg fp "$OUT1" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUse", tool_name: "Write", tool_input: {file_path: $fp, content: "hi again"}, tool_response: {success: true}}')"
outputs_len=$(state_field "$STATE_FILE" '.outputs | length')
assert_eq "PostToolUse(Write) duplicate path -> outputs deduped (len stays 1)" "1" "$outputs_len"

# --- PostToolUse (Edit) new file ---
OUT2="$FAKE_CWD/output2.txt"
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" --arg fp "$OUT2" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUse", tool_name: "Edit", tool_input: {file_path: $fp, old_string: "a", new_string: "b"}, tool_response: {success: true}}')"
outputs_len=$(state_field "$STATE_FILE" '.outputs | length')
assert_eq "PostToolUse(Edit) new path -> outputs grows to 2" "2" "$outputs_len"

# --- PostToolUse (Read) should NOT be tracked as an output ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUse", tool_name: "Read", tool_input: {file_path: "/tmp/whatever.txt"}, tool_response: {}}')"
outputs_len=$(state_field "$STATE_FILE" '.outputs | length')
assert_eq "PostToolUse(Read) -> outputs unchanged (still 2)" "2" "$outputs_len"

# --- PostToolUseFailure x3 -> error state ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUseFailure", tool_name: "Bash", tool_input: {command: "false"}, error: "exit 1", is_interrupt: false}')"
err_val=$(state_field "$STATE_FILE" '.error_count')
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "PostToolUseFailure #1 -> error_count 1" "1" "$err_val"
assert_eq "PostToolUseFailure #1 -> state stays working" "working" "$state_val"

run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUseFailure", tool_name: "Bash", tool_input: {command: "false"}, error: "exit 1", is_interrupt: false}')"
err_val=$(state_field "$STATE_FILE" '.error_count')
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "PostToolUseFailure #2 -> error_count 2" "2" "$err_val"
assert_eq "PostToolUseFailure #2 -> state stays working" "working" "$state_val"

run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUseFailure", tool_name: "Bash", tool_input: {command: "false"}, error: "exit 1", is_interrupt: false}')"
err_val=$(state_field "$STATE_FILE" '.error_count')
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "PostToolUseFailure #3 -> error_count 3" "3" "$err_val"
assert_eq "PostToolUseFailure #3 (3 consecutive) -> state error" "error" "$state_val"

# --- A successful PostToolUse resets error_count and clears error state ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: "echo ok"}, tool_response: {success: true}}')"
err_val=$(state_field "$STATE_FILE" '.error_count')
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "successful PostToolUse -> error_count reset to 0" "0" "$err_val"
assert_eq "successful PostToolUse -> state back to working" "working" "$state_val"

# --- Notification permission_prompt ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "Notification", message: "Claude needs your permission", title: "Permission needed", notification_type: "permission_prompt"}')"
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "Notification(permission_prompt) -> state waiting_permission" "waiting_permission" "$state_val"

# --- Notification idle_prompt ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "Notification", message: "idle", notification_type: "idle_prompt"}')"
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "Notification(idle_prompt) -> state waiting_input" "waiting_input" "$state_val"

# --- Stop ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: "done"}')"
state_val=$(state_field "$STATE_FILE" '.state')
assert_eq "Stop -> state done" "done" "$state_val"
outputs_len=$(state_field "$STATE_FILE" '.outputs | length')
assert_eq "Stop -> outputs preserved (still 2)" "2" "$outputs_len"

# --- SessionEnd ---
run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$SESSION_ID" --arg cwd "$FAKE_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "SessionEnd", reason: "other"}')"
assert_true "SessionEnd -> state file deleted" "$( [ ! -f "$STATE_FILE" ] && echo 1 || echo 0 )"

echo ""
echo "== Section A2: outputs cap at 200 =="

CAP_SESSION="test-session-cap"
CAP_STATE_FILE="$STATE_DIR/$CAP_SESSION.json"
CAP_CWD="/tmp/fake-project-cap-test"
mkdir -p "$CAP_CWD"

run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$CAP_SESSION" --arg cwd "$CAP_CWD" \
  '{session_id: $sid, cwd: $cwd, hook_event_name: "SessionStart", source: "startup"}')"

i=1
while [ "$i" -le 205 ]; do
  run_hook "$STATE_DIR" "$($JQ_BIN -n --arg sid "$CAP_SESSION" --arg cwd "$CAP_CWD" --arg fp "$CAP_CWD/file-$i.txt" \
    '{session_id: $sid, cwd: $cwd, hook_event_name: "PostToolUse", tool_name: "Write", tool_input: {file_path: $fp, content: "x"}, tool_response: {success: true}}')"
  i=$((i + 1))
done

outputs_len=$(state_field "$CAP_STATE_FILE" '.outputs | length')
assert_eq "outputs capped at 200 after 205 writes" "200" "$outputs_len"

last_path=$("$JQ_BIN" -r '.outputs[-1]' "$CAP_STATE_FILE")
assert_eq "outputs cap keeps most recent entry" "$CAP_CWD/file-205.txt" "$last_path"

echo ""
echo "== Section B: install.sh / uninstall.sh round-trip =="

FIXTURE_SETTINGS="$TMP_ROOT/settings.json"
ORIGINAL_SETTINGS="$TMP_ROOT/settings.original.json"
SHARE_DIR="$TMP_ROOT/share/notch-otter"

"$JQ_BIN" -n '
{
  permissions: {
    allow: ["Bash(git *)", "Read(*)"],
    deny: []
  },
  hooks: {
    PreToolUse: [
      {
        matcher: "Bash",
        hooks: [
          {type: "command", command: "/path/to/existing-hook.sh"}
        ]
      }
    ]
  },
  otherSetting: "keep-me"
}
' > "$FIXTURE_SETTINGS"

cp "$FIXTURE_SETTINGS" "$ORIGINAL_SETTINGS"

OTTER_SETTINGS_FILE="$FIXTURE_SETTINGS" OTTER_SHARE_DIR="$SHARE_DIR" "$ENGINE_DIR/install.sh" > "$TMP_ROOT/install.out" 2> "$TMP_ROOT/install.err"
install_exit=$?
assert_eq "install.sh exits 0" "0" "$install_exit"

assert_true "install.sh created dispatcher script" "$( [ -x "$SHARE_DIR/otter-hook.sh" ] && echo 1 || echo 0 )"

BACKUP_FILE="$FIXTURE_SETTINGS.pre-otter.bak"
assert_true "install.sh created backup file" "$( [ -f "$BACKUP_FILE" ] && echo 1 || echo 0 )"

backup_matches_original=$("$JQ_BIN" -n --slurpfile a "$BACKUP_FILE" --slurpfile b "$ORIGINAL_SETTINGS" '$a[0] == $b[0]')
assert_eq "backup content matches pre-install settings" "true" "$backup_matches_original"

perms_unchanged=$("$JQ_BIN" -n --slurpfile a "$FIXTURE_SETTINGS" --slurpfile b "$ORIGINAL_SETTINGS" '$a[0].permissions == $b[0].permissions')
assert_eq "permissions untouched by install" "true" "$perms_unchanged"

other_unchanged=$("$JQ_BIN" -r '.otherSetting' "$FIXTURE_SETTINGS")
assert_eq "unrelated top-level key untouched by install" "keep-me" "$other_unchanged"

existing_hook_survives=$("$JQ_BIN" '[.hooks.PreToolUse[].hooks[] | select(.command == "/path/to/existing-hook.sh")] | length' "$FIXTURE_SETTINGS")
assert_eq "pre-existing PreToolUse hook survives install" "1" "$existing_hook_survives"

notch_pretooluse_count=$("$JQ_BIN" '[.hooks.PreToolUse[].hooks[] | select(.command | test("notch-otter"))] | length' "$FIXTURE_SETTINGS")
assert_eq "exactly one notch-otter PreToolUse entry after install" "1" "$notch_pretooluse_count"

all_events_present=true
for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure Stop Notification SessionEnd; do
  cnt=$("$JQ_BIN" --arg ev "$ev" '[.hooks[$ev][]?.hooks[]? | select(.command | test("notch-otter"))] | length' "$FIXTURE_SETTINGS")
  if [ "$cnt" != "1" ]; then
    all_events_present=false
    fail "event $ev has notch-otter hook registered (found $cnt)"
  fi
done
if [ "$all_events_present" = "true" ]; then
  pass "all 8 events have exactly one notch-otter hook registered"
fi

dispatcher_cmd=$("$JQ_BIN" -r '.hooks.SessionStart[0].hooks[0].command' "$FIXTURE_SETTINGS")
assert_eq "registered command points at share dir dispatcher" "$SHARE_DIR/otter-hook.sh" "$dispatcher_cmd"

async_val=$("$JQ_BIN" -r '.hooks.SessionStart[0].hooks[0].async' "$FIXTURE_SETTINGS")
assert_eq "registered hook has async true" "true" "$async_val"

timeout_val=$("$JQ_BIN" -r '.hooks.SessionStart[0].hooks[0].timeout' "$FIXTURE_SETTINGS")
assert_eq "registered hook has timeout 10" "10" "$timeout_val"

echo ""
echo "== Section B2: install.sh idempotency (run twice) =="

OTTER_SETTINGS_FILE="$FIXTURE_SETTINGS" OTTER_SHARE_DIR="$SHARE_DIR" "$ENGINE_DIR/install.sh" > "$TMP_ROOT/install2.out" 2> "$TMP_ROOT/install2.err"
install2_exit=$?
assert_eq "second install.sh run exits 0" "0" "$install2_exit"

pretooluse_total=$("$JQ_BIN" '.hooks.PreToolUse | length' "$FIXTURE_SETTINGS")
assert_eq "PreToolUse array still has exactly 2 entries after re-install (1 existing + 1 notch-otter)" "2" "$pretooluse_total"

notch_pretooluse_count=$("$JQ_BIN" '[.hooks.PreToolUse[].hooks[] | select(.command | test("notch-otter"))] | length' "$FIXTURE_SETTINGS")
assert_eq "still exactly one notch-otter PreToolUse entry after re-install" "1" "$notch_pretooluse_count"

sessionstart_count=$("$JQ_BIN" '.hooks.SessionStart | length' "$FIXTURE_SETTINGS")
assert_eq "SessionStart array not duplicated after re-install" "1" "$sessionstart_count"

echo ""
echo "== Section B3: uninstall.sh restores original state =="

OTTER_SETTINGS_FILE="$FIXTURE_SETTINGS" OTTER_SHARE_DIR="$SHARE_DIR" "$ENGINE_DIR/uninstall.sh" > "$TMP_ROOT/uninstall.out" 2> "$TMP_ROOT/uninstall.err"
uninstall_exit=$?
assert_eq "uninstall.sh exits 0" "0" "$uninstall_exit"

assert_true "uninstall.sh removed share dir" "$( [ ! -e "$SHARE_DIR" ] && echo 1 || echo 0 )"

perms_unchanged=$("$JQ_BIN" -n --slurpfile a "$FIXTURE_SETTINGS" --slurpfile b "$ORIGINAL_SETTINGS" '$a[0].permissions == $b[0].permissions')
assert_eq "permissions untouched by uninstall" "true" "$perms_unchanged"

other_unchanged=$("$JQ_BIN" -r '.otherSetting' "$FIXTURE_SETTINGS")
assert_eq "unrelated top-level key untouched by uninstall" "keep-me" "$other_unchanged"

hooks_equal_original=$("$JQ_BIN" -n --slurpfile a "$FIXTURE_SETTINGS" --slurpfile b "$ORIGINAL_SETTINGS" '$a[0].hooks == $b[0].hooks')
assert_eq "hooks block restored to original content after uninstall" "true" "$hooks_equal_original"

whole_file_equal_original=$("$JQ_BIN" -n --slurpfile a "$FIXTURE_SETTINGS" --slurpfile b "$ORIGINAL_SETTINGS" '$a[0] == $b[0]')
assert_eq "full settings file content-equal to pre-install original after uninstall" "true" "$whole_file_equal_original"

no_notch_events=$("$JQ_BIN" '[.hooks | keys[] | select(. as $k | ["SessionStart","UserPromptSubmit","PostToolUse","PostToolUseFailure","Stop","Notification","SessionEnd"] | index($k))] | length' "$FIXTURE_SETTINGS")
assert_eq "event keys that only had notch-otter hooks are fully removed" "0" "$no_notch_events"

echo ""
echo "== Section C: real ~/.claude settings files were never touched =="

REAL_CLAUDE_AFTER=$(real_claude_fingerprint)
assert_true "real ~/.claude settings and backup unchanged by test run" "$( [ "$REAL_CLAUDE_BEFORE" = "$REAL_CLAUDE_AFTER" ] && echo 1 || echo 0 )"

echo ""
echo "=================================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0

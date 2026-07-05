#!/usr/bin/env bash
# Writes a fake session state file into the notch-otter state directory and
# cycles it through working -> waiting_permission -> done every 5 seconds, so
# the app can be exercised manually without a real Claude Code session.
#
# Usage: scripts/fake_session.sh [project-name]
set -euo pipefail

PROJECT_NAME="${1:-demo-project}"
STATE_DIR="$HOME/.local/state/notch-otter/sessions"
SESSION_ID="fake-$$"
SESSION_FILE="$STATE_DIR/$SESSION_ID.json"
TMP_FILE="$SESSION_FILE.tmp"
CWD="$HOME/Repos/$PROJECT_NAME"

mkdir -p "$STATE_DIR"

cleanup() {
  echo ""
  echo "==> Removing fake session $SESSION_ID"
  rm -f "$SESSION_FILE" "$TMP_FILE"
}
# Only EXIT is bound directly to cleanup. INT/TERM must explicitly `exit`,
# otherwise bash runs the trap handler and then resumes the while-loop below
# instead of terminating the process.
trap cleanup EXIT
trap 'exit 0' INT TERM

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Bash only runs signal traps between commands, so a single `sleep 5` can
# delay INT/TERM handling by up to 5 seconds. Sleeping in 1-second increments
# bounds that delay to ~1 second so Ctrl-C / kill feel responsive.
snooze() {
  local remaining="$1"
  while (( remaining > 0 )); do
    sleep 1
    remaining=$((remaining - 1))
  done
}

write_state() {
  local state="$1"
  local error_count="${2:-0}"
  local outputs_json="${3:-[]}"
  cat > "$TMP_FILE" <<JSON
{
  "session_id": "$SESSION_ID",
  "state": "$state",
  "cwd": "$CWD",
  "project": "$PROJECT_NAME",
  "pid": $$,
  "updated_at": "$(now_iso)",
  "last_event": "fake_session.sh",
  "error_count": $error_count,
  "outputs": $outputs_json
}
JSON
  mv "$TMP_FILE" "$SESSION_FILE"
  echo "==> $SESSION_ID -> $state"
}

echo "==> Faking session '$SESSION_ID' for project '$PROJECT_NAME'"
echo "==> Writing to $SESSION_FILE (pid $$, cycling every 5s, Ctrl-C to stop)"

while true; do
  write_state "working" 0 "[]"
  snooze 5
  write_state "waiting_permission" 0 "[]"
  snooze 5
  write_state "done" 0 "[\"$CWD/README.md\", \"$CWD/output.txt\"]"
  snooze 5
done

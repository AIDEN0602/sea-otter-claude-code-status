#!/bin/sh
# Installs the NotchOtter hook dispatcher into a Claude Code settings.json
# file, per SPEC.md section 2.
#
# Env overrides (for testing, never touch the real files unless intended):
#   OTTER_SETTINGS_FILE  - settings.json path (default: ~/.claude/settings.json)
#   OTTER_SHARE_DIR      - where otter-hook.sh is copied (default: ~/.local/share/notch-otter)

set -eu

JQ_BIN="/usr/bin/jq"
SETTINGS_FILE="${OTTER_SETTINGS_FILE:-$HOME/.claude/settings.json}"
SHARE_DIR="${OTTER_SHARE_DIR:-$HOME/.local/share/notch-otter}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

EVENTS_JSON='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","Stop","Notification","SessionEnd"]'

# 1. Stage the dispatcher script.
mkdir -p "$SHARE_DIR"
cp "$SCRIPT_DIR/otter-hook.sh" "$SHARE_DIR/otter-hook.sh"
chmod +x "$SHARE_DIR/otter-hook.sh"
CMD="$SHARE_DIR/otter-hook.sh"

# 2. Load (or initialize) the settings file, validating it first.
mkdir -p "$(dirname "$SETTINGS_FILE")"

if [ -f "$SETTINGS_FILE" ]; then
  current=$(cat "$SETTINGS_FILE")
else
  current='{}'
fi

if ! printf '%s' "$current" | "$JQ_BIN" empty >/dev/null 2>&1; then
  echo "otter-install: $SETTINGS_FILE is not valid JSON, aborting without changes" >&2
  exit 1
fi

# 3. Back up the original settings file exactly once.
BACKUP="$SETTINGS_FILE.pre-otter.bak"
if [ -f "$SETTINGS_FILE" ] && [ ! -f "$BACKUP" ]; then
  cp "$SETTINGS_FILE" "$BACKUP"
fi

# 4. Merge our hooks in. For each of our events, strip any pre-existing
# notch-otter entries (idempotency / upgrade-in-place) then append a fresh
# one. Entries belonging to other tools are left untouched. Events we don't
# own are never read or written.
new=$(printf '%s' "$current" | "$JQ_BIN" \
  --arg cmd "$CMD" \
  --argjson events "$EVENTS_JSON" \
  '
  def strip_notch(arr):
    arr
    | map(.hooks = ((.hooks // []) | map(select((.command // "" | test("notch-otter")) | not))))
    | map(select((.hooks | length) > 0));

  def upsert_event(ev; cmd):
    (.[ev] // []) as $arr
    | (strip_notch($arr)) as $cleaned
    | .[ev] = ($cleaned + [{"hooks": [{"type": "command", "command": cmd, "async": true, "timeout": 10}]}]);

  (if has("hooks") then . else . + {hooks: {}} end)
  | .hooks = (
      .hooks
      | reduce $events[] as $ev (.; upsert_event($ev; $cmd))
    )
  ')

if ! printf '%s' "$new" | "$JQ_BIN" empty >/dev/null 2>&1; then
  echo "otter-install: generated settings JSON failed validation, aborting without changes" >&2
  exit 1
fi

# 5. Atomically replace the settings file.
tmp="$SETTINGS_FILE.tmp.$$"
printf '%s' "$new" | "$JQ_BIN" '.' > "$tmp"
mv "$tmp" "$SETTINGS_FILE"

echo "NotchOtter hooks installed into $SETTINGS_FILE"
echo "Dispatcher: $CMD"

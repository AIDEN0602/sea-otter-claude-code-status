#!/bin/sh
# Removes the NotchOtter hook dispatcher from a Claude Code settings.json
# file, per SPEC.md section 2. Only removes entries whose command contains
# "notch-otter"; everything else in the settings file is left intact.
#
# Env overrides (for testing, never touch the real files unless intended):
#   OTTER_SETTINGS_FILE  - settings.json path (default: ~/.claude/settings.json)
#   OTTER_SHARE_DIR      - dispatcher install dir to remove (default: ~/.local/share/notch-otter)

set -eu

JQ_BIN="/usr/bin/jq"
SETTINGS_FILE="${OTTER_SETTINGS_FILE:-$HOME/.claude/settings.json}"
SHARE_DIR="${OTTER_SHARE_DIR:-$HOME/.local/share/notch-otter}"

if [ -f "$SETTINGS_FILE" ]; then
  current=$(cat "$SETTINGS_FILE")

  if ! printf '%s' "$current" | "$JQ_BIN" empty >/dev/null 2>&1; then
    echo "otter-uninstall: $SETTINGS_FILE is not valid JSON, aborting without changes" >&2
    exit 1
  fi

  new=$(printf '%s' "$current" | "$JQ_BIN" '
    if has("hooks") then
      .hooks = (
        .hooks
        | with_entries(
            .value |= (
              map(.hooks = ((.hooks // []) | map(select((.command // "" | test("notch-otter")) | not))))
              | map(select((.hooks | length) > 0))
            )
          )
        | with_entries(select((.value | length) > 0))
      )
    else
      .
    end
  ')

  if ! printf '%s' "$new" | "$JQ_BIN" empty >/dev/null 2>&1; then
    echo "otter-uninstall: generated settings JSON failed validation, aborting without changes" >&2
    exit 1
  fi

  tmp="$SETTINGS_FILE.tmp.$$"
  printf '%s' "$new" | "$JQ_BIN" '.' > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"
  echo "NotchOtter hooks removed from $SETTINGS_FILE"
else
  echo "otter-uninstall: $SETTINGS_FILE not found, nothing to remove there" >&2
fi

rm -rf "$SHARE_DIR"
echo "Removed $SHARE_DIR"

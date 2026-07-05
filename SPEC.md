# NotchOtter — Shared Contract (v1)

All components MUST conform to this spec. Change here first, then in code.

## 1. Session state files

Directory: `~/.local/state/notch-otter/sessions/`
One file per live Claude Code session: `<session_id>.json`

```json
{
  "session_id": "abc-123",
  "state": "idle | working | waiting_permission | waiting_input | done | error | stale",
  "cwd": "/Users/minje-work-mac/Repos/foo",
  "project": "foo",
  "pid": 12345,
  "updated_at": "2026-07-05T14:03:22Z",
  "last_event": "PreToolUse",
  "error_count": 0,
  "outputs": ["/abs/path/file1.py", "/abs/path/report.html"]
}
```

Rules:
- Writes are ATOMIC: write to `<session_id>.json.tmp` then `mv` over.
- `pid` = the `claude` process PID, captured as `$PPID` inside the hook (hook runs as child of claude).
- `outputs` = deduplicated absolute paths from PostToolUse Write/Edit events, append-only, max 200.
- `state` transitions (hook → state):
  - SessionStart → `idle`
  - UserPromptSubmit, PreToolUse, PostToolUse → `working`
  - Notification type `permission_prompt` → `waiting_permission`
  - Notification type `idle_prompt` → `waiting_input`
  - Stop → `done` (keep outputs)
  - PostToolUseFailure → increment `error_count`; state → `error` only if 3+ consecutive failures, else stays `working`. Any successful PostToolUse resets `error_count` to 0.
  - SessionEnd → delete the file
- `stale` is NEVER written by hooks; only the app marks stale (PID dead + no SessionEnd), then removes the file after 60s.

## 2. Hook registration

Installed into `~/.claude/settings.json` (user scope) by `engine/install.sh`:
- Events: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, Stop, Notification, SessionEnd
- All hooks: `{"type":"command","command":"~/.local/share/notch-otter/otter-hook.sh","async":true,"timeout":10}`
  (single dispatcher script; branches on `hook_event_name` from stdin JSON; uses `/usr/bin/jq`)
- install.sh MUST merge into existing hooks arrays (never overwrite other hooks) and back up settings.json to `settings.json.pre-otter.bak` on first install.
- uninstall.sh MUST remove only entries whose command contains `notch-otter`, leaving everything else intact.

## 3. Sprite sheets

Directory: `assets/sprites/` (PNG, RGBA, transparent background)
- Base cell: 32x32 px, laid out horizontally per animation.
- One file per state: `idle.png`, `working.png`, `waiting_permission.png`, `waiting_input.png`, `done.png`, `error.png`, `stale.png`
- 2–4 frames each; frame count = width / 32.
- Palette: warm brown otter, cream belly, black nose; must read well on pure black (#000) notch background.
- The app scales with nearest-neighbor (pixel-perfect) to ~24pt display height.

## 4. App behavior (summary)

- NSPanel pinned right of the notch, black background, non-activating, all-Spaces.
- Shows: one otter (animated, state = highest-priority session state: error > waiting_permission > waiting_input > working > done > idle) + text badge `"3 working · 1 waiting"`.
- Click otter → dropdown panel: one row per session (project name, state icon, age, outputs count). Row click → AppleScript focus Ghostty tab matching `cwd`; outputs button → open outputs folder in Finder.
- Watches sessions dir via DispatchSource/FSEvents; PID liveness poll every 5s.
- Notifications (UNUserNotificationCenter): fire on transitions INTO waiting_permission, done, error. Never on working/idle.
- On `done` with non-empty outputs: create `~/Desktop/Otter Outputs/<YYYY-MM-DD>-<project>/` containing symlinks to output paths.

## 5. Repo layout

```
notch-otter/
  SPEC.md
  engine/            # otter-hook.sh, install.sh, uninstall.sh, test_engine.sh
  spritegen/         # gen_sprites.py (PIL), outputs to assets/sprites/
  assets/sprites/
  app/               # Swift package (Package.swift, Sources/NotchOtter/*)
  scripts/           # build_app.sh (SPM build → .app bundle → ad-hoc codesign)
```

All code, comments, commits in English.

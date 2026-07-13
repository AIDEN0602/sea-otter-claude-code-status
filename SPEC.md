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
  "launch_cwd": "/Users/minje-work-mac/Repos/foo",
  "project": "foo",
  "pid": 12345,
  "tty": "ttys014",
  "updated_at": "2026-07-05T14:03:22Z",
  "last_event": "PreToolUse",
  "error_count": 0,
  "outputs": ["/abs/path/file1.py", "/abs/path/report.html"],
  "last_summary": "Fixed the build; tests pass. Next up: wiring the panel."
}
```

Rules:
- Writes are ATOMIC: write to `<session_id>.json.tmp` then `mv` over.
- `pid` = the `claude` process PID, captured as `$PPID` inside the hook (hook runs as child of claude).
- `launch_cwd` (string) = the `cwd` from the FIRST event that creates the state file, captured once and never overwritten afterward. `cwd` itself keeps updating on every event (Claude's internal `cd` changes it), but the Ghostty tab that launched the session keeps reporting the original launch directory, so the app needs `launch_cwd` for tab matching.
- `tty` (string, optional) = the claude process's controlling tty (e.g. `"ttys014"`), captured once via `ps -o tty= -p $PPID` the same way `pid` is backfilled: only re-attempted while the state file lacks a non-empty `tty`, so it's at most one extra `ps` call per session lifetime, not per event. A `"??"` (no controlling tty) result is stored as empty/absent so the app can treat it as unknown.
- `outputs` = deduplicated absolute paths from PostToolUse Write/Edit events, append-only, max 200.
- `last_summary` (string, optional) = short single-line excerpt (max 200 codepoints) of the most recent assistant reply, refreshed on every event that carries a `transcript_path`: the last `type=="assistant"` line WITH text blocks within the transcript's final 60 lines (tool-use-only entries are skipped), cleaned of code fences / markdown glyphs / link syntax, whitespace collapsed. Replies longer than 200 codepoints are condensed to "first sentence … last sentence" (outcome + next step) rather than cut mid-word. Notification events with a non-empty `message` use that message instead (it names the pending tool for permission prompts). Truncation is codepoint-based in jq — never byte-based (`cut -c`), which could split a UTF-8 sequence and corrupt the file. Shown in the desktop pet's hover bubble. `engine/backfill_summaries.sh` injects it once into state files that predate the field (sessions idle since before hook install would otherwise show an empty bubble until their next event).
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

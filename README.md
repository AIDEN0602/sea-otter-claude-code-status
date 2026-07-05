# NotchOtter

A pixel-art otter that lives next to your MacBook notch and shows the live status
of every Claude Code session running in your terminal (Ghostty or any other).

- One glance: otter animation = highest-priority state across sessions
  (error > waiting for permission > waiting for input > working > done > idle),
  plus a badge like `3 working · 1 waiting`.
- Click the otter: dropdown listing each session (project, state, age, outputs).
  Click a row to focus the matching Ghostty tab (uses Ghostty >= 1.3 AppleScript).
- macOS notifications when a session needs permission approval, finishes, or errors —
  visible even when you're in Chrome or anywhere else.
- When a session finishes, files it created/edited are symlinked into
  `~/Desktop/Otter Outputs/<date>-<project>/`.
- Dead-session detection: closing a terminal tab without a clean exit is caught by a
  PID liveness check; the session is marked stale and removed.

## How it works

```
Claude Code session ──(hooks, all events)──▶ otter-hook.sh ──▶ ~/.local/state/notch-otter/sessions/<id>.json
                                                                        ▲
NotchOtter.app ── FSEvents watch + 5s PID poll ────────────────────────┘
```

Hooks are pure `sh` + `jq`, always exit 0, never block Claude. The app is a small
native AppKit binary (no Electron), built with SPM only (no Xcode required).

## Install

```bash
# 1. Register hooks (merges into ~/.claude/settings.json, backs up first)
bash engine/install.sh

# 2. Build the app bundle (requires Swift toolchain / CommandLineTools)
bash scripts/build_app.sh

# 3. Launch
open dist/NotchOtter.app
```

First launch: allow the Notifications prompt, and (on first tab-jump) the
"control Ghostty" Automation prompt. Use the menu bar item → "Launch at Login"
to keep it running.

## Uninstall

```bash
bash engine/uninstall.sh   # removes only NotchOtter hooks, restores everything else
```

## Repo layout

See `SPEC.md` for the full contract (state schema, transitions, sprite format).

- `engine/` — hook dispatcher, install/uninstall, test suite (`bash engine/test_engine.sh`)
- `spritegen/` — procedural pixel-art sprite generator (Python/Pillow)
- `assets/sprites/` — generated sprite sheets (variant A ships in the app)
- `app/` — Swift package (AppKit, macOS 13+)
- `scripts/` — `build_app.sh` (bundle + ad-hoc codesign), `fake_session.sh` (demo)

#!/usr/bin/env bash
# Bundles the entire NotchOtter source tree (text files only — sprites are
# regenerated from code) into a single self-contained REBUILD.md that another
# Claude/agent can turn back into a working repo and build. Files are wrapped
# in unique unicode markers so triple-backticks inside the sources never break
# parsing.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OUT="REBUILD.md"

FILES=(
  app/Package.swift
  app/Sources/NotchOtter/main.swift
  app/Sources/NotchOtter/AppDelegate.swift
  app/Sources/NotchOtter/Session.swift
  app/Sources/NotchOtter/SessionStore.swift
  app/Sources/NotchOtter/SessionRowView.swift
  app/Sources/NotchOtter/NotchGeometry.swift
  app/Sources/NotchOtter/NotchPanel.swift
  app/Sources/NotchOtter/CompanionPanel.swift
  app/Sources/NotchOtter/DesktopPetPanel.swift
  app/Sources/NotchOtter/DropdownPanel.swift
  app/Sources/NotchOtter/OtterSpriteView.swift
  app/Sources/NotchOtter/SpritePacks.swift
  app/Sources/NotchOtter/StatusBarController.swift
  app/Sources/NotchOtter/PreferencesWindowController.swift
  app/Sources/NotchOtter/TerminalFocuser.swift
  app/Sources/NotchOtter/TerminalPreference.swift
  app/Sources/NotchOtter/TerminalFocusDispatcher.swift
  app/Sources/NotchOtter/GhosttyFocus.swift
  app/Sources/NotchOtter/GhosttyTabMatching.swift
  app/Sources/NotchOtter/GhosttyTabsPoller.swift
  app/Sources/NotchOtter/ITerm2Focus.swift
  app/Sources/NotchOtter/AppleTerminalFocus.swift
  app/Sources/NotchOtter/NotificationManager.swift
  app/Sources/NotchOtter/OutputsManager.swift
  scripts/build_app.sh
  scripts/gen-icon.swift
  spritegen/gen_sprites.py
  engine/install.sh
  engine/uninstall.sh
  engine/otter-hook.sh
)

{
  cat <<'HEADER'
# NotchOtter — Source Bundle (rebuild from this file)

This single Markdown file contains the full source of **NotchOtter**, a macOS
menu bar / notch pet that shows what every Claude Code session is doing.

## For the assistant reading this

Reconstruct the repository and build it:

1. For every block below, create the file at the exact path shown in its
   `FILE:` marker, writing the content **verbatim** (everything between the
   `⟦⟦⟦ FILE: ... ⟧⟧⟧` line and the matching `⟦⟦⟦ END ⟧⟧⟧` line).
2. Regenerate the otter sprite art from code (needs Python + Pillow):
   `pip3 install pillow` then `python3 spritegen/gen_sprites.py`.
   This writes the PNG sprite sheets under `assets/sprites/`.
3. Make sure the build script's sprite source directory exists. If
   `gen_sprites.py` wrote to a variant folder other than
   `assets/sprites/chatgpt`, either copy it there or edit `SPRITES_SRC`
   near the top of `scripts/build_app.sh` to point at the folder that was
   created.
4. Build and install: `bash scripts/build_app.sh`
   (needs macOS 13+ and Xcode Command Line Tools). It builds a release,
   generates an app icon, ad-hoc codesigns, and installs
   `/Applications/NotchOtter.app`.
5. `open "/Applications/NotchOtter.app"`. First launch may show an
   "unidentified developer" warning — right-click the app → Open → Open.
6. To wire up the Claude Code hooks that feed the otter:
   `bash engine/install.sh` (it backs up the user's settings first).

The parsing format is delimiter-based (not code fences) on purpose, so
triple-backticks inside the sources are preserved exactly. Do not
"reformat" the code — write it byte-for-byte.

---
HEADER

  for f in "${FILES[@]}"; do
    printf '\n⟦⟦⟦ FILE: %s ⟧⟧⟧\n' "$f"
    cat "$f"
    printf '\n⟦⟦⟦ END ⟧⟧⟧\n'
  done
} > "$OUT"

echo "Wrote $OUT ($(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1))"

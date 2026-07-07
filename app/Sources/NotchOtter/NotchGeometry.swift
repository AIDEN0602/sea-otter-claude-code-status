import AppKit

/// Computes where to place the notch panel so it reads as a true horizontal
/// extension of the physical notch, not a floating overlay: flush against
/// one of the notch's edges (zero gap) and spanning the exact same height as
/// the menu bar / safe-area strip.
enum NotchGeometry {
    /// Real-world measurements of the notch on a given screen, derived from
    /// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` when the
    /// system exposes them (macOS 12+, notched hardware only).
    struct NotchMetrics {
        /// X position (screen coordinates) immediately left of the notch --
        /// a panel to the left of the notch must have its RIGHT edge here.
        let leftEdgeX: CGFloat
        /// X position (screen coordinates) immediately right of the notch --
        /// a panel to the right of the notch must have its LEFT edge here.
        let rightEdgeX: CGFloat
        /// Height of the menu bar / safe-area strip the notch lives in.
        /// This is `safeAreaInsets.top`; never hardcode a menu bar constant.
        let stripHeight: CGFloat
        /// Physical width of the notch itself, for reference/debugging.
        let notchWidth: CGFloat
    }

    /// Returns notch metrics for `screen`, or nil on hardware with no notch
    /// (safeAreaInsets.top == 0).
    static func metrics(for screen: NSScreen) -> NotchMetrics? {
        let stripHeight = screen.safeAreaInsets.top
        guard stripHeight > 0 else { return nil }

        if let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea {
            // The two aux areas are the strip to the left and right of the
            // notch; the gap between them is the notch itself. These are the
            // exact, authoritative edges -- equivalent to the
            // "screenWidth/2 +/- notchWidth/2" formula when the notch is
            // perfectly centered, but reading the aux area rects directly
            // avoids the rounding drift that formula introduces when the two
            // aux areas aren't perfectly symmetric (observed ~0.5pt drift on
            // real hardware).
            let notchWidth = rightArea.minX - leftArea.maxX
            return NotchMetrics(
                leftEdgeX: leftArea.maxX,
                rightEdgeX: rightArea.minX,
                stripHeight: stripHeight,
                notchWidth: notchWidth
            )
        }

        // Aux areas unavailable (shouldn't happen on real notched hardware,
        // but guard for older SDKs / misreporting screens): fall back to the
        // screenWidth/2 +/- notchWidth/2 formula with an estimated notch
        // width scaled from the strip height (current notches run roughly 6x
        // their height in width).
        let estimatedNotchWidth = stripHeight * 6
        let centerX = screen.frame.midX
        return NotchMetrics(
            leftEdgeX: centerX - estimatedNotchWidth / 2,
            rightEdgeX: centerX + estimatedNotchWidth / 2,
            stripHeight: stripHeight,
            notchWidth: estimatedNotchWidth
        )
    }

    /// The screen the island panel should live on: the notched (built-in)
    /// display when one is active, otherwise the main screen -- so in
    /// clamshell mode the panel becomes a fake Dynamic Island at the top
    /// center of the external monitor instead of disappearing.
    static var islandScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    /// Frame (screen coordinates) for a Dynamic-Island-style panel hanging
    /// directly BELOW the notch: horizontally centered on the notch, top edge
    /// flush with the bottom of the menu bar / safe-area strip, so the black
    /// panel reads as the notch itself extending downward. On screens with no
    /// notch (external monitors / clamshell mode) it hangs below the menu bar
    /// at top center, reading as a standalone Dynamic Island pill.
    static func panelFrameBelowNotch(on screen: NSScreen, size: NSSize) -> NSRect {
        let screenFrame = screen.frame

        if let notch = metrics(for: screen) {
            let centerX = (notch.leftEdgeX + notch.rightEdgeX) / 2
            let y = screenFrame.maxY - notch.stripHeight - size.height
            return NSRect(x: centerX - size.width / 2, y: y, width: size.width, height: size.height)
        }

        // No notch: hang just below the actual menu bar (its height is the
        // gap between the screen frame and the visible frame; safeAreaInsets
        // is 0 here so it can't be used).
        let menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY
        let y = screenFrame.maxY - menuBarHeight - size.height
        return NSRect(x: screenFrame.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }

    /// True when the main screen reports a physical notch.
    static var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }
}

import AppKit

/// Computes where to place the notch panel so it reads as a true horizontal
/// extension of the physical notch, not a floating overlay: flush against
/// the notch's right edge (zero gap) and spanning the exact same height as
/// the menu bar / safe-area strip.
enum NotchGeometry {
    /// Real-world measurements of the notch on a given screen, derived from
    /// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` when the
    /// system exposes them (macOS 12+, notched hardware only).
    struct NotchMetrics {
        /// X position (screen coordinates) immediately right of the notch --
        /// this is where our panel's left edge must sit with zero gap.
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
            // notch; the gap between them is the notch itself. This is the
            // exact, authoritative edge -- equivalent to the requested
            // "screenWidth/2 + notchWidth/2" formula when the notch is
            // perfectly centered, but reading `rightArea.minX` directly
            // avoids the +/-0.5pt rounding drift that formula introduces
            // when the two aux areas aren't perfectly symmetric.
            let notchWidth = rightArea.minX - leftArea.maxX
            return NotchMetrics(rightEdgeX: rightArea.minX, stripHeight: stripHeight, notchWidth: notchWidth)
        }

        // Aux areas unavailable (shouldn't happen on real notched hardware,
        // but guard for older SDKs / misreporting screens): fall back to the
        // screenWidth/2 + notchWidth/2 formula with an estimated notch width
        // scaled from the strip height (current notches run roughly 6x
        // their height in width).
        let estimatedNotchWidth = stripHeight * 6
        let rightEdgeX = screen.frame.midX + estimatedNotchWidth / 2
        return NotchMetrics(rightEdgeX: rightEdgeX, stripHeight: stripHeight, notchWidth: estimatedNotchWidth)
    }

    /// Frame (screen coordinates) for a panel of `width`: flush against the
    /// notch's right edge, y = 0 from the top of the screen, height = the
    /// exact strip height (never a hardcoded constant). Falls back to a
    /// standard-menu-bar-height, top-center placement on screens with no
    /// notch.
    static func panelFrame(on screen: NSScreen, width: CGFloat) -> NSRect {
        let screenFrame = screen.frame

        if let notch = metrics(for: screen) {
            let y = screenFrame.maxY - notch.stripHeight
            return NSRect(x: notch.rightEdgeX, y: y, width: width, height: notch.stripHeight)
        }

        // No notch: standard 24pt menu bar strip, centered.
        let fallbackHeight: CGFloat = 24
        let y = screenFrame.maxY - fallbackHeight
        let x = screenFrame.midX - (width / 2)
        return NSRect(x: x, y: y, width: width, height: fallbackHeight)
    }

    /// True when the main screen reports a physical notch.
    static var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }
}

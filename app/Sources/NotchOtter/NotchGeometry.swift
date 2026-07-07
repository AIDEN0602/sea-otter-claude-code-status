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

    /// How far the panel slides UNDER the notch's left edge. The current
    /// sprite sheet bakes transparent margins into each square cell, so a
    /// panel that stops exactly at the notch edge leaves the otter looking
    /// detached from it; overhanging by this much hides the margin beneath
    /// the (black) notch and puts the otter's body visually flush against
    /// the notch. Invisible on the notch itself; applied on notched screens
    /// only.
    private static let notchOverhang: CGFloat = 6

    /// Frame (screen coordinates) for a panel of `width` positioned
    /// immediately LEFT of the notch (panel's right edge tucked slightly
    /// under the notch's left edge so the otter reads as touching it),
    /// spanning the exact strip height. Falls back to a
    /// standard-menu-bar-height placement on screens with no notch.
    static func panelFrameLeftOfNotch(on screen: NSScreen, width: CGFloat) -> NSRect {
        let screenFrame = screen.frame

        if let notch = metrics(for: screen) {
            let y = screenFrame.maxY - notch.stripHeight
            let x = notch.leftEdgeX - width + notchOverhang
            return NSRect(x: x, y: y, width: width, height: notch.stripHeight)
        }

        // No notch: standard 24pt menu bar strip; park near top-center since
        // "left of the notch" is meaningless without one.
        let fallbackHeight: CGFloat = 24
        let y = screenFrame.maxY - fallbackHeight
        let x = screenFrame.midX - width
        return NSRect(x: x, y: y, width: width, height: fallbackHeight)
    }

    /// The screen the notch panel should live on: the notched (built-in)
    /// display when one is active, otherwise the main screen (clamshell mode
    /// falls back to the menu bar strip of the external monitor).
    static var panelScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    /// True when the main screen reports a physical notch.
    static var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }
}

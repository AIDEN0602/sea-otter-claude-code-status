import AppKit

/// Computes where to place the notch panel: flush against the top edge of the
/// screen, immediately to the right of the physical notch when one exists.
enum NotchGeometry {
    /// Returns the frame (in screen coordinates) for a panel of `size`,
    /// positioned immediately right of the notch and flush with the top of
    /// the screen. Falls back to a top-center placement on screens with no
    /// notch (safeAreaInsets.top == 0 or the aux areas are unavailable).
    static func panelFrame(on screen: NSScreen, size: NSSize) -> NSRect {
        let screenFrame = screen.frame
        let topY = screenFrame.maxY - size.height

        if screen.safeAreaInsets.top > 0, let rightArea = screen.auxiliaryTopRightArea {
            let x = rightArea.minX
            return NSRect(x: x, y: topY, width: size.width, height: size.height)
        }

        // No notch: center the panel at the top of the screen, just under the
        // menu bar strip so it doesn't collide with the system status items.
        let x = screenFrame.midX - (size.width / 2)
        return NSRect(x: x, y: topY, width: size.width, height: size.height)
    }

    /// True when the main screen reports a physical notch.
    static var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0 && screen.auxiliaryTopRightArea != nil
    }
}

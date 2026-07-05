import AppKit

/// Displays one frame of a state's sprite sheet at a time, stepping through
/// frames on a timer with nearest-neighbor (pixel-perfect) scaling.
/// Sprite sheets are loaded from `Contents/Resources/sprites/<state>.png`,
/// laid out horizontally in 32x32 cells (frame count = width / 32), per
/// SPEC.md section 3.
final class OtterSpriteView: NSView {
    private static let cellSize: CGFloat = 32
    private static let frameInterval: TimeInterval = 0.4

    private let imageLayer = CALayer()
    private var frames: [CGImage] = []
    private var frameIndex = 0
    private var timer: Timer?
    private var loadedState: SessionState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.actions = ["contents": NSNull()] // disable implicit fade between frames
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    /// Switches the displayed animation to `state`. No-op if already showing it.
    func setState(_ state: SessionState) {
        guard state != loadedState else { return }
        loadedState = state
        frames = Self.loadFrames(for: state)
        frameIndex = 0
        timer?.invalidate()
        timer = nil

        guard !frames.isEmpty else {
            imageLayer.contents = nil
            return
        }

        imageLayer.contents = frames[0]
        guard frames.count > 1 else { return }

        let newTimer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        imageLayer.contents = frames[frameIndex]
    }

    private static func loadFrames(for state: SessionState) -> [CGImage] {
        guard let url = Bundle.main.url(
            forResource: state.rawValue,
            withExtension: "png",
            subdirectory: "sprites"
        ), let image = NSImage(contentsOf: url) else {
            return []
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        let cellPixels = Int(cellSize)
        guard cellPixels > 0, pixelWidth >= cellPixels, pixelHeight > 0 else {
            return [cgImage]
        }

        let frameCount = max(1, pixelWidth / cellPixels)
        var slices: [CGImage] = []
        slices.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let rect = CGRect(x: i * cellPixels, y: 0, width: cellPixels, height: pixelHeight)
            if let slice = cgImage.cropping(to: rect) {
                slices.append(slice)
            }
        }
        return slices.isEmpty ? [cgImage] : slices
    }

    deinit {
        timer?.invalidate()
    }
}

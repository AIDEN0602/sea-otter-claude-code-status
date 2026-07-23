// Generates AppIcon.png (1024x1024) for NotchOtter: dark navy squircle in
// the shared app family, with the first otter sprite frame centered on it.
// Run: swift scripts/gen-icon.swift <sprite-sheet.png> <out.png>
import AppKit

let args = CommandLine.arguments
let spritePath = args.count > 1 ? args[1] : "assets/sprites/chatgpt/idle.png"
let out = args.count > 2 ? args[2] : "AppIcon.png"

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Background squircle, same family as the other apps (dark navy gradient).
let inset = size * 0.05
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
NSGradient(colors: [
    NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.10, alpha: 1),
])!.draw(in: path, angle: -90)

// Crop the first frame out of the horizontal sprite sheet.
guard let sheet = NSImage(contentsOfFile: spritePath),
      let tiff = sheet.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    fatalError("Could not load sprite sheet at \(spritePath)")
}
let sheetW = CGFloat(rep.pixelsWide)
let sheetH = CGFloat(rep.pixelsHigh)
let frameW = sheetW / 3.0            // three frames side by side
let frameRect = CGRect(x: 0, y: 0, width: frameW, height: sheetH)
guard let cg = rep.cgImage?.cropping(to: frameRect) else {
    fatalError("Could not crop sprite frame")
}
let frame = NSImage(cgImage: cg, size: NSSize(width: frameW, height: sheetH))

// Draw the otter centered, scaled to ~62% of the icon, nearest-neighbor so
// the pixel art stays crisp.
NSGraphicsContext.current?.imageInterpolation = .none
let target = size * 0.62
let aspect = frameW / sheetH
let drawW = target * aspect
let drawH = target
let drawRect = NSRect(x: (size - drawW) / 2, y: (size - drawH) / 2 - size * 0.02,
                      width: drawW, height: drawH)
frame.draw(in: drawRect)

image.unlockFocus()
guard let outTiff = image.tiffRepresentation,
      let outRep = NSBitmapImageRep(data: outTiff),
      let png = outRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render icon")
}
try! png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")

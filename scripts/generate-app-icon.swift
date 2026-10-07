// Original Plenty Strong artwork. Native build-time tooling only; not an app target.
// Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/generate-app-icon.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let destination = URL(fileURLWithPath: "PlentyStrong/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.shouldAntialias = true
NSColor(srgbRed: 0.075, green: 0.235, blue: 0.195, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
NSColor(srgbRed: 0.96, green: 0.945, blue: 0.855, alpha: 1).setFill()
// Dumbbell: four rounded plates and a single continuous handle.
for rectangle in [NSRect(x: 205, y: 352, width: 95, height: 320),
                  NSRect(x: 315, y: 300, width: 110, height: 424),
                  NSRect(x: 599, y: 300, width: 110, height: 424),
                  NSRect(x: 724, y: 352, width: 95, height: 320),
                  NSRect(x: 390, y: 468, width: 244, height: 88)] {
    NSBezierPath(roundedRect: rectangle, xRadius: 24, yRadius: 24).fill()
}
// An original leaf, suggesting steady growth, above the handle.
NSColor(srgbRed: 0.69, green: 0.83, blue: 0.46, alpha: 1).setFill()
let leaf = NSBezierPath()
leaf.move(to: NSPoint(x: 466, y: 600))
leaf.curve(to: NSPoint(x: 595, y: 798), controlPoint1: NSPoint(x: 450, y: 715), controlPoint2: NSPoint(x: 520, y: 797))
leaf.curve(to: NSPoint(x: 466, y: 600), controlPoint1: NSPoint(x: 640, y: 665), controlPoint2: NSPoint(x: 553, y: 616))
leaf.close(); leaf.fill()
NSGraphicsContext.restoreGraphicsState()
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
// AppKit requires an RGBA drawing surface. Encode through an opaque RGB surface.
let opaque = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
opaque.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
let encoder = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(encoder, opaque.makeImage()!, nil)
guard CGImageDestinationFinalize(encoder) else { fatalError("Could not encode original icon") }
print("Wrote opaque RGB 1024px original icon: \(destination.path)")

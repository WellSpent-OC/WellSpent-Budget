// Renders the app icon into every size macOS wants and packs them into
// Sources/WellSpentApp/Resources/AppIcon.icns. Run with `make icon`.
//
// With `iphone PATH`, it draws the iPhone's icon instead: the same drawing, full
// bleed and opaque, one 1024 pixel square written to PATH. The master draws a
// rounded square inside a clear edge, and an iPhone icon is a plain square the
// phone rounds itself, so the drawing is scaled until its square fills the frame.
// Run with `make iphone-icon`.
//
// Two drawings, by size. Design/AppIcon/AppIcon.svg is for 32 pixels and up.
// Design/AppIcon/AppIcon_Small.svg, with thicker lines and fewer parts, is for
// the 16 pixel slot, where the full drawing turns to texture. The 16 point
// slot at double size is 32 pixels, so it takes the full drawing.
//
// AppKit draws SVG itself, so this needs no image tools beyond what ships with
// macOS: this script and `iconutil`.
import AppKit

func drawing(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)) else { fatalError("Could not read \(path)") }
    return image
}

let full = drawing("Design/AppIcon/AppIcon.svg")
let small = drawing("Design/AppIcon/AppIcon_Small.svg")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The iPhone's icon: the master's 824 point square, from 100 to 924, scaled to
/// fill 1024 pixels, on the square's own black, with no alpha channel, as the App
/// Store asks.
func iPhonePNG(_ image: NSImage) -> Data {
    let pixels = 1024
    // AppKit draws only into a bitmap with alpha, so the drawing goes into a Core
    // Graphics canvas that has none.
    let canvas = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    let scale = 1024.0 / 824.0
    image.draw(in: NSRect(x: -100 * scale, y: -100 * scale, width: 1024 * scale, height: 1024 * scale))
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "iphone" {
    let out = URL(fileURLWithPath: CommandLine.arguments[2])
    try! iPhonePNG(full).write(to: out)
    print(out.path)
    exit(0)
}

for points in [16, 32, 128, 256, 512] {
    let oneX = points == 16 ? small : full
    try! png(oneX, points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(full, points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print(iconset.path)

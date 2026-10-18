// Renders the app icon into every size macOS wants and packs them into
// Sources/WellSpentApp/Resources/AppIcon.icns. Run with `make icon`.
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

for points in [16, 32, 128, 256, 512] {
    let oneX = points == 16 ? small : full
    try! png(oneX, points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(full, points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print(iconset.path)

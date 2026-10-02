// Renders Design/AppIcon/AppIcon.svg into every size macOS wants and packs them
// into Sources/WellSpentApp/Resources/AppIcon.icns. Run with `make icon`.
//
// AppKit draws SVG itself, so this needs no image tools beyond what ships with
// macOS: this script and `iconutil`.
import AppKit

let svg = URL(fileURLWithPath: "Design/AppIcon/AppIcon.svg")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
guard let image = NSImage(contentsOf: svg) else { fatalError("Could not read \(svg.path)") }

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ pixels: Int) -> Data {
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
    try! png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print(iconset.path)

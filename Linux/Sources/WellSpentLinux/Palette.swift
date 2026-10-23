import SwiftCrossUI
import WellSpentAppCore

/// The shared colours (`PaletteValues`), for the Linux screens. SwiftCrossUI
/// cannot tell whether the desktop is dark, so each colour is its light value,
/// as the Mac draws it.
enum Palette {
    static let ground = Color(PaletteValues.ground)
    static let surface = Color(PaletteValues.surface)
    static let sidebar = Color(PaletteValues.sidebar)
    static let ink = Color(PaletteValues.ink)
    static let muted = Color(PaletteValues.muted)
    static let line = Color(PaletteValues.line)
    static let track = Color(PaletteValues.track)
    static let accent = Color(PaletteValues.accent)
    static let warning = Color(PaletteValues.warning)
    static let blue = Color(PaletteValues.blue)
    static let budgetColors = PaletteValues.budgetColors.map { Color($0) }
}

extension Color {
    init(_ pair: ColorPair) {
        self.init(red: pair.light.red, green: pair.light.green, blue: pair.light.blue)
    }
}

extension Font {
    static func money(_ size: Double, weight: Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

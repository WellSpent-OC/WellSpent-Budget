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

    // Linux desktop dark chrome and extension rail styling
    static let railBackground = Color(red: 0.07, green: 0.07, blue: 0.07) // #121212
    static let railButtonActive = Color(red: 0.15, green: 0.15, blue: 0.15) // #262626
    static let railBorder = Color(red: 0.16, green: 0.16, blue: 0.16) // #292929
    static let titlebarBackground = Color(red: 0.09, green: 0.09, blue: 0.09) // #171717
    static let gold = Color(red: 0.83, green: 0.69, blue: 0.22) // #D4AF37
    static let goldLight = Color(red: 0.96, green: 0.72, blue: 0.19) // #F5B731
    static let sidebarDark = Color(red: 0.125, green: 0.125, blue: 0.125) // #202020
    static let sidebarHeader = Color(red: 0.54, green: 0.54, blue: 0.54) // #8A8A8A
    static let sidebarDivider = Color(red: 0.24, green: 0.24, blue: 0.24) // #3D3D3D
    static let sidebarText = Color(red: 0.80, green: 0.80, blue: 0.80) // #CCCCCC
    static let sidebarPill = Color(red: 0.96, green: 0.93, blue: 0.86) // #F4EEDC
    static let sidebarPillText = Color(red: 0.09, green: 0.09, blue: 0.09) // #171717
    static let ringGreen = Color(red: 0.46, green: 0.64, blue: 0.30) // #76A24D
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

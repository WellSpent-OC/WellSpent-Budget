import SwiftCrossUI
import WellSpentAppCore

/// The shared colours (`PaletteValues`), for the Linux screens. SwiftCrossUI
/// cannot tell whether the desktop is dark, so each colour is its light value,
/// as the Mac draws it.
enum Palette {
    /// Small words.
    static let muted = Color(PaletteValues.muted)
    /// A problem, and what stands in the way.
    static let warning = Color(PaletteValues.warning)
}

extension Color {
    init(_ pair: ColorPair) {
        self.init(red: pair.light.red, green: pair.light.green, blue: pair.light.blue)
    }
}

import Foundation

/// A colour as red, green and blue in sRGB, each from 0 to 1.
public struct RGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From a hex value, as the design pages write colours: 0x2B2823.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// How light it looks, from 0 for black to 1 for white, measured the way
    /// the contrast rules for readable text measure it (WCAG 2).
    public var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast between two colours, from 1 to 21. Words need 4.5 to 1
    /// on what they sit on. Edges and fills need 3 to 1.
    public func contrast(with other: RGB) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// One colour, with its twin for dark mode.
public struct ColorPair: Equatable, Sendable {
    public let light: RGB
    public let dark: RGB

    public init(light: RGB, dark: RGB) {
        self.light = light
        self.dark = dark
    }
}

/// Today's colours, each with its dark twin, kept in one place so the Mac,
/// the iPhone and later the Linux app cannot drift apart. The SwiftUI screens
/// draw them through `Palette`. On a phone it follows the device's light or
/// dark setting. The Mac draws the light values until dark mode is placed in
/// a Mac build.
///
/// The light values are the ones the Mac has always drawn. The dark values
/// come from the dark mode design wherever today's look has the same part:
/// the page, the cards, the words, small words, row lines, the bar's track,
/// fields and the warning. Today's green, blue and purple have no part there,
/// so their dark twins are lighter colours of the same hue, measured the same
/// way.
public enum PaletteValues {
    /// The page behind everything.
    public static let ground = ColorPair(light: RGB(red: 0.965, green: 0.957, blue: 0.941), dark: RGB(hex: 0x2B2823))
    /// A budget's page, cards and sheets.
    public static let surface = ColorPair(light: RGB(red: 0.992, green: 0.988, blue: 0.980), dark: RGB(hex: 0x36322C))
    /// The sidebar's cream, used as a well behind a link or a list of people.
    /// In dark mode it takes the fields' colour, a step darker than a card.
    public static let sidebar = ColorPair(light: RGB(red: 0.937, green: 0.922, blue: 0.894), dark: RGB(hex: 0x24211D))
    /// Words.
    public static let ink = ColorPair(light: RGB(red: 0.098, green: 0.110, blue: 0.106), dark: RGB(hex: 0xF2EEE4))
    /// Small words.
    public static let muted = ColorPair(light: RGB(red: 0.369, green: 0.388, blue: 0.376), dark: RGB(hex: 0xB5AE9F))
    /// Row lines.
    public static let line = ColorPair(light: RGB(red: 0.886, green: 0.871, blue: 0.843), dark: RGB(hex: 0x4D473F))
    /// The empty part of a budget's bar. A line's colour in light mode, as
    /// before, and darker than the card in dark mode.
    public static let track = ColorPair(light: line.light, dark: RGB(hex: 0x1F1D19))
    /// The bar's fill, the first budget colour, and a matched import line.
    public static let accent = ColorPair(light: RGB(red: 0.122, green: 0.373, blue: 0.294), dark: RGB(hex: 0x66B89A))
    /// Over budget, a failure, and the last budget colour. The light one is
    /// #A84D27, a little darker than the first #B4532A, so the Over figure
    /// reads in a group's MONEY well too: 4.72 to 1 on the well, where it was
    /// 4.20.
    public static let warning = ColorPair(light: RGB(red: 0.657, green: 0.302, blue: 0.153), dark: RGB(hex: 0xE38D66))
    /// The second budget colour, and an import line to add.
    public static let blue = ColorPair(light: RGB(red: 0.169, green: 0.361, blue: 0.494), dark: RGB(hex: 0x7FB2D9))
    /// The third budget colour.
    public static let purple = ColorPair(light: RGB(red: 0.478, green: 0.290, blue: 0.549), dark: RGB(hex: 0xB98FCB))

    /// A budget's dot, by its colour index: these four, then round again.
    public static let budgetColors = [accent, blue, purple, warning]

    // MARK: - The money wheel

    // A budget's row in the list is drawn as its own bar, in the row fill
    // design's colours. Its words are near-black in light mode. In dark mode
    // the names take the band's colour the design measured as white, and the
    // amounts a softer grey. The wheel's colours are design 2's ring.

    /// A row's empty track.
    public static let rowTrack = ColorPair(light: RGB(hex: 0xE5DFD5), dark: RGB(hex: 0x242424))
    /// A row's fill, as far as its budget is used.
    public static let rowUsed = ColorPair(light: RGB(hex: 0xD5E6C2), dark: RGB(hex: 0x3D5E2E))
    /// A row's fill when its budget is over.
    public static let rowOver = ColorPair(light: RGB(hex: 0xF0C8B5), dark: RGB(hex: 0x8A3A1C))
    /// The budget's name on a row.
    public static let rowWords = ColorPair(light: RGB(hex: 0x111111), dark: RGB(hex: 0xF2F2F2))
    /// The amount on a row.
    public static let rowAmount = ColorPair(light: RGB(hex: 0x111111), dark: RGB(hex: 0xD9D9D9))
    /// The 2 point outline round the open budget's row. The dark value is the
    /// dark mode design's sticker outline.
    public static let rowOutline = ColorPair(light: RGB(hex: 0x111111), dark: RGB(hex: 0xF2EEE4))
    /// The wheel's empty band. In dark mode it is the bar's dark track.
    public static let wheelTrack = ColorPair(light: RGB(hex: 0xE5DFD5), dark: RGB(hex: 0x1F1D19))
    /// What is left, on the wheel. The same green in both modes.
    public static let wheelLeft = ColorPair(light: RGB(hex: 0x76A24D), dark: RGB(hex: 0x76A24D))
    /// The wheel's two edges and its tick.
    public static let wheelEdge = ColorPair(light: RGB(hex: 0x111111), dark: RGB(hex: 0xF2EEE4))

    /// The design's dark band. It is the same in light and dark, and words
    /// on it are white.
    public static let band = ColorPair(light: RGB(hex: 0x1A1A1A), dark: RGB(hex: 0x1A1A1A))

    /// The fills behind Edit and Delete when an entry's row is swiped on a
    /// phone. The system writes their words in white, so they are the same
    /// in light and dark.
    public static let swipeEdit = band
    public static let swipeDelete = ColorPair(light: RGB(hex: 0xB4532A), dark: RGB(hex: 0xB4532A))

    /// The bar on a phone after a delete: the band with white words, and
    /// Undo as a gold button with near-black words. The design draws it the
    /// same in light and dark.
    public static let undoBar = band
    public static let undoBarWords = ColorPair(light: RGB(hex: 0xFFFFFF), dark: RGB(hex: 0xFFFFFF))
    public static let undoButton = ColorPair(light: RGB(hex: 0xD4AF37), dark: RGB(hex: 0xD4AF37))
    public static let undoButtonWords = ColorPair(light: RGB(hex: 0x111111), dark: RGB(hex: 0x111111))
}

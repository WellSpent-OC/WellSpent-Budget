import Testing
@testable import WellSpentAppCore

/// Today's colours and their dark twins, measured the way the dark mode design
/// measures them: words need 4.5 to 1 on what they sit on, and the bar's fills
/// 3 to 1 against its track. These run on every platform, Linux included.
@Suite("Colours, light and dark")
struct PaletteValuesTests {
    /// Every colour the screens write words in.
    static let words: [(String, ColorPair)] = [
        ("words", PaletteValues.ink), ("small words", PaletteValues.muted), ("warning", PaletteValues.warning),
        ("green", PaletteValues.accent), ("blue", PaletteValues.blue),
    ]

    @Test func everyWordColourReadsOnThePageAndOnACardInLightAndDark() {
        let grounds = [("the page", PaletteValues.ground), ("a card", PaletteValues.surface)]
        for (word, colour) in Self.words {
            for (ground, behind) in grounds {
                #expect(colour.light.contrast(with: behind.light) >= 4.5, "\(word) on \(ground), light")
                #expect(colour.dark.contrast(with: behind.dark) >= 4.5, "\(word) on \(ground), dark")
            }
        }
    }

    /// The wells behind a link or a list of people hold words and small words.
    @Test func wordsReadInAWellInLightAndDark() {
        for colour in [PaletteValues.ink, PaletteValues.muted] {
            #expect(colour.light.contrast(with: PaletteValues.sidebar.light) >= 4.5)
            #expect(colour.dark.contrast(with: PaletteValues.sidebar.dark) >= 4.5)
        }
    }

    @Test func theBarsFillsShowAgainstItsTrackAndEveryBudgetDotShowsOnAWell() {
        for fill in [PaletteValues.accent, PaletteValues.warning] {
            #expect(fill.light.contrast(with: PaletteValues.track.light) >= 3)
            #expect(fill.dark.contrast(with: PaletteValues.track.dark) >= 3)
        }
        for dot in PaletteValues.budgetColors {
            #expect(dot.light.contrast(with: PaletteValues.sidebar.light) >= 3)
            #expect(dot.dark.contrast(with: PaletteValues.sidebar.dark) >= 3)
        }
    }

    /// The measure agrees with the design's own published figures, so the
    /// checks above mean what they say.
    @Test func contrastIsMeasuredAsTheDesignMeasuresIt() {
        let white = RGB(hex: 0xFFFFFF), black = RGB(hex: 0x000000)
        #expect(abs(white.contrast(with: black) - 21) < 0.001)
        #expect(abs(black.contrast(with: white) - 21) < 0.001, "the same either way round")
        // Words on a card in dark mode: 11.0 to 1. The icon's green on the
        // dark track: 5.6 to 1. Small words on a card: 5.8 to 1.
        #expect(abs(RGB(hex: 0xF2EEE4).contrast(with: RGB(hex: 0x36322C)) - 11.0) < 0.05)
        #expect(abs(RGB(hex: 0x76A24D).contrast(with: RGB(hex: 0x1F1D19)) - 5.6) < 0.05)
        #expect(abs(RGB(hex: 0xB5AE9F).contrast(with: RGB(hex: 0x36322C)) - 5.8) < 0.05)
    }

    /// Light mode keeps exactly the colours the Mac has always drawn.
    @Test func lightModeIsTodaysLook() {
        #expect(PaletteValues.surface.light == RGB(red: 0.992, green: 0.988, blue: 0.980))
        #expect(PaletteValues.accent.light == RGB(red: 0.122, green: 0.373, blue: 0.294))
        #expect(PaletteValues.warning.light == RGB(red: 0.706, green: 0.325, blue: 0.165))
        #expect(PaletteValues.track.light == PaletteValues.line.light)
        #expect(PaletteValues.budgetColors.map(\.light) == [
            RGB(red: 0.122, green: 0.373, blue: 0.294), RGB(red: 0.169, green: 0.361, blue: 0.494),
            RGB(red: 0.478, green: 0.290, blue: 0.549), RGB(red: 0.706, green: 0.325, blue: 0.165),
        ])
    }
}

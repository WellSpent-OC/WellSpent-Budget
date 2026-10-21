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

    /// Words on a green button, such as a phone's Add, are drawn in the page's
    /// colour. White reads at only 2.4 to 1 on the dark green.
    @Test func wordsOnTheGreenReadInLightAndDark() {
        #expect(PaletteValues.ground.light.contrast(with: PaletteValues.accent.light) >= 4.5)
        #expect(PaletteValues.ground.dark.contrast(with: PaletteValues.accent.dark) >= 4.5)
        #expect(RGB(hex: 0xFFFFFF).contrast(with: PaletteValues.accent.dark) < 4.5, "why not white")
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

    // MARK: - The money wheel

    /// A row's three colours: its track, its fill, and its fill when over.
    static let rowColours: [(String, ColorPair)] = [
        ("the track", PaletteValues.rowTrack), ("the fill", PaletteValues.rowUsed),
        ("the over fill", PaletteValues.rowOver),
    ]

    // Scenario WHEEL-04
    @Test func theRowAndWheelColoursAreTheDesignsOwn() {
        func pair(_ light: UInt32, _ dark: UInt32) -> ColorPair {
            ColorPair(light: RGB(hex: light), dark: RGB(hex: dark))
        }
        #expect(PaletteValues.rowTrack == pair(0xE5DFD5, 0x242424))
        #expect(PaletteValues.rowUsed == pair(0xD5E6C2, 0x3D5E2E))
        #expect(PaletteValues.rowOver == pair(0xF0C8B5, 0x8A3A1C))
        #expect(PaletteValues.rowWords == pair(0x111111, 0xF2F2F2))
        #expect(PaletteValues.rowAmount == pair(0x111111, 0xD9D9D9))
        #expect(PaletteValues.rowOutline == pair(0x111111, 0xF2EEE4))
        #expect(PaletteValues.wheelTrack == pair(0xE5DFD5, 0x1F1D19))
        #expect(PaletteValues.wheelLeft == pair(0x76A24D, 0x76A24D))
        #expect(PaletteValues.wheelEdge == pair(0x111111, 0xF2EEE4))
    }

    // Scenario WHEEL-04
    @Test func aRowsNameAndAmountReadOnItsTrackAndItsFillInLightAndDark() {
        for (word, colour) in [("the name", PaletteValues.rowWords), ("the amount", PaletteValues.rowAmount)] {
            for (part, behind) in Self.rowColours {
                #expect(colour.light.contrast(with: behind.light) >= 4.5, "\(word) on \(part), light")
                #expect(colour.dark.contrast(with: behind.dark) >= 4.5, "\(word) on \(part), dark")
            }
        }
    }

    /// The row fill design's own figures, to within a tenth: near-black
    /// words read at 14.3, 14.3 and 12.3 to 1 in light mode, the dark names
    /// at 13.9, 6.6 and 6.9, and the dark amounts at 11.0, 5.2 and 5.5.
    @Test func theRowsContrastIsWhatTheDesignMeasured() {
        let measured: [(ColorPair, [Double], [Double])] = [
            (PaletteValues.rowWords, [14.3, 14.3, 12.3], [13.9, 6.6, 6.9]),
            (PaletteValues.rowAmount, [14.3, 14.3, 12.3], [11.0, 5.2, 5.5]),
        ]
        for (colour, light, dark) in measured {
            for ((_, behind), (lightFigure, darkFigure)) in zip(Self.rowColours, zip(light, dark)) {
                #expect(abs(colour.light.contrast(with: behind.light) - lightFigure) < 0.1)
                #expect(abs(colour.dark.contrast(with: behind.dark) - darkFigure) < 0.1)
            }
        }
    }

    // Scenario WHEEL-03
    @Test func theOpenBudgetsOutlineShowsOnEveryRowColour() {
        for (part, behind) in Self.rowColours {
            #expect(PaletteValues.rowOutline.light.contrast(with: behind.light) >= 3, "on \(part), light")
            #expect(PaletteValues.rowOutline.dark.contrast(with: behind.dark) >= 3, "on \(part), dark")
        }
    }

    /// The wheel's edges and tick show on its track, on a card and on the
    /// page. Its warning shows on its track, and so does its green in dark
    /// mode. The light green on the light track is the design's choice, at
    /// 2.25 to 1: the black edges frame it, and words carry every number.
    @Test func theWheelsEdgesAndWarningShowOnItsTrack() {
        for behind in [PaletteValues.wheelTrack, PaletteValues.surface, PaletteValues.ground] {
            #expect(PaletteValues.wheelEdge.light.contrast(with: behind.light) >= 3)
            #expect(PaletteValues.wheelEdge.dark.contrast(with: behind.dark) >= 3)
        }
        #expect(PaletteValues.warning.light.contrast(with: PaletteValues.wheelTrack.light) >= 3)
        #expect(PaletteValues.warning.dark.contrast(with: PaletteValues.wheelTrack.dark) >= 3)
        #expect(PaletteValues.wheelLeft.dark.contrast(with: PaletteValues.wheelTrack.dark) >= 3)
    }
}

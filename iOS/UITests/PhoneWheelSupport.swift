// What the money wheel's UI tests need on top of PhoneTestSupport.swift and
// TodaysBudget: the day the app counts as today, waiting for a label, and
// reading the colour on screen at a point, so a test can see a row's fill
// and a wheel's ring the way a person does.
import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentModel

extension PhoneTestApp {
    /// The day the app counts as today when launched with `countingAsToday:
    /// day`, worked out by the same shared code: noon on that day of this
    /// month. Nil for a day this month does not have.
    static func pinnedToday(_ day: Int) -> Date? {
        PinnedDay.requested(in: [PinnedDay.variable: String(day)], environment: .staging)
    }

    /// Waits until the element's label is exactly these words.
    @discardableResult
    func waitForLabel(_ identifier: String, toBe label: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label),
                                                    object: element(identifier))
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits until the element's label holds these words.
    @discardableResult
    func waitForLabel(_ identifier: String, toContain words: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", words),
                                                    object: element(identifier))
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Whether the phone is set to dark mode for this run. make
    /// iphone-ui-test sets it before the run: a test cannot change it on a
    /// simulator with no window.
    var isDark: Bool { XCUIDevice.shared.appearance == .dark }

    /// What the screen shows now, to read colours from.
    func screenColours() -> ScreenColours {
        ScreenColours(XCUIScreen.main.screenshot().image, screenWidth: app.frame.width)
    }

    /// The point on a wheel's ring a share of the way round, clockwise from
    /// the top, at a distance from its middle.
    static func point(on wheel: XCUIElement, share: Double, radius: Double) -> CGPoint {
        let angle = Double.pi * 3 / 2 + 2 * Double.pi * share
        return CGPoint(x: wheel.frame.midX + radius * cos(angle), y: wheel.frame.midY + radius * sin(angle))
    }

    /// Shares of the way round inside this range, each well clear of the
    /// tick, so a check of the ring's colour never lands on the tick.
    static func shares(in range: ClosedRange<Double>, clearOf tick: Double?) -> [Double] {
        let steps = range.lowerBound == range.upperBound ? 0 : 8
        return (0 ... steps).map { range.lowerBound + (range.upperBound - range.lowerBound) * Double($0) / Double(max(steps, 1)) }
            .filter { share in
                guard let tick else { return true }
                let apart = abs(share - tick).truncatingRemainder(dividingBy: 1)
                return min(apart, 1 - apart) > 0.03
            }
    }

    /// Fails unless the screen shows each colour where it is expected, in
    /// the value for the phone's light or dark setting. A change takes a
    /// moment to draw, so it looks again until the time runs out, then names
    /// every part that showed something else.
    func expectColours(_ checks: [ColourCheck], timeout: TimeInterval = 5,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(checks.isEmpty, "no colour to check", file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        var wrong: [String] = []
        repeat {
            let screen = screenColours()
            let dark = isDark
            wrong = checks.compactMap { check in
                let expected = dark ? check.colour.dark : check.colour.light
                let seen = screen.colour(at: check.point)
                guard !ScreenColours.isClose(seen, expected) else { return nil }
                return "\(check.part) at \(check.point) is \(ScreenColours.hex(seen)), not \(ScreenColours.hex(expected))"
            }
            if wrong.isEmpty { return }
            // A short pause before looking again.
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "a moment to draw")], timeout: 0.5)
        } while Date() < deadline
        XCTFail("in \(isDark ? "dark" : "light") mode: " + wrong.joined(separator: "; "), file: file, line: line)
    }
}

/// One colour a test expects on screen: which part, where, and its light
/// and dark values.
struct ColourCheck {
    let part: String
    let colour: ColorPair
    let point: CGPoint
}

/// One screenshot's colours, read in sRGB, the space the palette's hex
/// values are written in.
struct ScreenColours {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    /// Pixels to a point.
    private let scale: CGFloat

    init(_ image: UIImage, screenWidth: CGFloat) {
        let cgImage = image.cgImage
        width = cgImage?.width ?? 0
        height = cgImage?.height ?? 0
        scale = screenWidth > 0 ? CGFloat(width) / screenWidth : 1
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        if let cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.pixels = pixels
    }

    /// The colour at a point on screen, in points from the top left.
    func colour(at point: CGPoint) -> RGB {
        let x = min(max(Int((point.x * scale).rounded(.down)), 0), max(width - 1, 0))
        let y = min(max(Int((point.y * scale).rounded(.down)), 0), max(height - 1, 0))
        let index = (y * width + x) * 4
        guard index + 2 < pixels.count else { return RGB(red: 0, green: 0, blue: 0) }
        return RGB(red: Double(pixels[index]) / 255, green: Double(pixels[index + 1]) / 255,
                   blue: Double(pixels[index + 2]) / 255)
    }

    /// Close enough to be the same colour once drawn and read back: within
    /// 10 of 255 in each of red, green and blue.
    static func isClose(_ one: RGB, _ other: RGB) -> Bool {
        let tolerance = 10.0 / 255
        return abs(one.red - other.red) <= tolerance && abs(one.green - other.green) <= tolerance
            && abs(one.blue - other.blue) <= tolerance
    }

    /// "#E5DFD5", for a failure message.
    static func hex(_ colour: RGB) -> String {
        String(format: "#%02X%02X%02X", Int((colour.red * 255).rounded()), Int((colour.green * 255).rounded()),
               Int((colour.blue * 255).rounded()))
    }
}

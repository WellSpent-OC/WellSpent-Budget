import Foundation
import XCTest
import WellSpentAppCore

/// Reading the statement review on the Mac: what each line says will happen
/// to it, and the counts across the top. Shared by the import tests and the
/// repeat tests, which both check a review.

/// A text on screen, with where it is.
struct ShownText {
    let words: String
    let identifier: String
    let frame: CGRect
}

@MainActor
extension TestApp {
    /// The words under `root`, read from one snapshot, and the frames of the
    /// elements named `identifier`, when one is given.
    func look(in root: XCUIElement, for identifier: String? = nil) -> (texts: [ShownText], frames: [CGRect]) {
        guard let snapshot = try? root.snapshot() else { return ([], []) }
        var texts: [ShownText] = []
        var frames: [CGRect] = []
        var waiting = [snapshot]
        while let node = waiting.popLast() {
            if let identifier, node.identifier == identifier { frames.append(node.frame) }
            if node.elementType == .staticText {
                let words = node.label.isEmpty ? (node.value as? String ?? "") : node.label
                if !words.isEmpty { texts.append(ShownText(words: words, identifier: node.identifier, frame: node.frame)) }
            }
            waiting.append(contentsOf: node.children)
        }
        return (texts, frames)
    }

    /// The review, while it is open: the sheet with Import on it.
    var review: XCUIElement {
        app.sheets.containing(.any, identifier: AccessibilityID.importConfirm).firstMatch
    }

    /// What a line says will happen to it.
    func status(of bank: String) -> String {
        let status = element(AccessibilityID.importLineStatus(bank))
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no row for \(bank). On screen: \(visibleTexts())")
        return text(of: status)
    }

    /// A count's name at the top of the review. What a line says will happen
    /// to it can be the same words, so those are left out.
    func countName(_ name: String, in texts: [ShownText]) -> ShownText? {
        texts.first { $0.words == name && !$0.identifier.hasPrefix(AccessibilityID.importLineStatus("")) }
    }

    /// One count at the top of the review, as it reads: the number under its
    /// name.
    func count(_ name: String, in texts: [ShownText]) -> String {
        guard let label = countName(name, in: texts) else { return "no count called \(name)" }
        let under: [ShownText] = texts.filter { (text: ShownText) -> Bool in
            let sameColumn: Bool = abs(text.frame.minX - label.frame.minX) < 4
            let justBelow: Bool = text.frame.minY >= label.frame.midY && text.frame.minY - label.frame.maxY < 24
            return text.words.allSatisfy(\.isNumber) && sameColumn && justBelow
        }
        return under.min { $0.frame.minY < $1.frame.minY }?.words ?? "no number under \(name)"
    }

    func count(_ name: String) -> String {
        count(name, in: look(in: review).texts)
    }
}

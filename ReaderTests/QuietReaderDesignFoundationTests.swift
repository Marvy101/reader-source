import XCTest
@testable import Reader

final class QuietReaderDesignFoundationTests: XCTestCase {
    func testMarkSelectionIsDeterministicAndCaseInsensitive() {
        let first = QuietAccountMark.deterministic(for: "Ishmael")
        let second = QuietAccountMark.deterministic(for: "ishmael")

        XCTAssertEqual(first, second)
    }

    func testDifferentNamesCanSelectDifferentMarks() {
        let marks = ["Ishmael", "Queequeg", "Ahab", "Starbuck", "Pip"]
            .map(QuietAccountMark.deterministic(for:))

        XCTAssertGreaterThan(Set(marks).count, 1)
    }

    @MainActor
    func testNewToastReplacesCurrentToast() {
        let center = QuietToastCenter()

        center.show("kept", kind: .done)
        center.show("couldn't open that file", kind: .stop)

        XCTAssertEqual(center.current?.message, "couldn't open that file")
        XCTAssertEqual(center.current?.kind, .stop)
    }

    @MainActor
    func testToastVoiceIsLowercaseWithoutTerminalPunctuation() {
        let center = QuietToastCenter()

        center.show("We'll send you a link.", kind: .note)

        XCTAssertEqual(center.current?.message, "we'll send you a link")
    }
}

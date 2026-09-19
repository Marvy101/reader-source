import XCTest
@testable import Reader

final class ReaderTextIndexTests: XCTestCase {
    func testSearchReturnsCanonicalCrossFormatLocator() throws {
        let index = ReaderTextIndex(
            publicationFingerprint: "book-sha",
            chunks: [
                PublicationTextChunk(
                    resourceID: "chapter-7",
                    title: "A Mad Tea-Party",
                    text: "There was a table set out under a tree in front of the house.",
                    ordinal: 6
                )
            ]
        )

        let result = try XCTUnwrap(index.search("TABLE").first)

        XCTAssertEqual(result.locator.schemaVersion, 1)
        XCTAssertEqual(result.locator.publicationFingerprint, "book-sha")
        XCTAssertEqual(result.locator.resourceID, "chapter-7")
        XCTAssertEqual(result.locator.position, 12)
        XCTAssertEqual(result.locator.textAnchor?.exact.lowercased(), "table")
        XCTAssertEqual(result.resourceTitle, "A Mad Tea-Party")
        XCTAssertTrue(result.excerpt.contains("table set out"))
    }

    func testSearchSpansResourcesAndHonorsLimit() {
        let index = ReaderTextIndex(
            publicationFingerprint: "book-sha",
            chunks: [
                PublicationTextChunk(
                    resourceID: "one",
                    title: "One",
                    text: "Alice Alice",
                    ordinal: 0
                ),
                PublicationTextChunk(
                    resourceID: "two",
                    title: "Two",
                    text: "Alice",
                    ordinal: 1
                )
            ]
        )

        let results = index.search("alice", limit: 2)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.locator.resourceID), ["one", "one"])
    }

    func testBlankQueryReturnsNoResults() {
        let index = ReaderTextIndex(
            publicationFingerprint: "book-sha",
            chunks: []
        )

        XCTAssertTrue(index.search(" \n ").isEmpty)
    }

    func testSelectionContextIsBoundedAndCrossesResourceBoundaries() {
        let index = ReaderTextIndex(
            publicationFingerprint: "book-sha",
            chunks: [
                PublicationTextChunk(
                    resourceID: "one",
                    title: "One",
                    text: "Earlier context.",
                    ordinal: 0
                ),
                PublicationTextChunk(
                    resourceID: "two",
                    title: "Two",
                    text: "Before SELECTED after.",
                    ordinal: 1
                ),
                PublicationTextChunk(
                    resourceID: "three",
                    title: "Three",
                    text: "Later context.",
                    ordinal: 2
                ),
            ]
        )
        let selection = ReaderSelection(
            locator: ReaderLocator(
                publicationFingerprint: "book-sha",
                resourceID: "two",
                position: 7,
                progression: 0.3
            ),
            selectedText: "SELECTED"
        )

        let context = index.context(
            around: selection,
            maximumCharactersPerSide: 24
        )

        XCTAssertTrue(context.before.hasSuffix("Before "))
        XCTAssertTrue(context.before.contains("context."))
        XCTAssertTrue(context.after.hasPrefix(" after."))
        XCTAssertTrue(context.after.contains("Later"))
        XCTAssertLessThanOrEqual(context.before.count, 26)
        XCTAssertLessThanOrEqual(context.after.count, 26)
    }
}

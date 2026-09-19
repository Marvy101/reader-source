import Foundation
import XCTest
@testable import Reader

@MainActor
final class EPUBGeneratedDocumentTests: XCTestCase {
    func testGeneratedMobyDickDocumentContainsBookMarkupNotSQLDescriptions() throws {
        let sourceURL = ReaderTestCorpus.downloadDirectory
            .appending(path: "moby-dick.epub")
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: sourceURL.path),
            "Run scripts/download_test_corpus.sh first."
        )

        let publication = try EPUBPublicationLoader.load(from: sourceURL)
        let documentURL = try EPUBContinuousDocumentBuilder.build(
            publication: publication
        )
        let markup = try String(contentsOf: documentURL, encoding: .utf8)

        XCTAssertTrue(markup.contains("class=\"reader-resource"))
        XCTAssertTrue(markup.contains("CHAPTER 1. Loomings."))
        XCTAssertFalse(markup.contains("GRDB.SQL"))
        XCTAssertFalse(markup.contains("SQL(elements:"))
    }
}

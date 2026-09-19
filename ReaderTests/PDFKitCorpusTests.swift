import Foundation
import PDFKit
import XCTest

final class PDFKitCorpusTests: XCTestCase {
    private struct Manifest: Decodable {
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let id: String
        let fileName: String
        let format: String
        let expectedPageCount: Int?
        let expectedTextCharacters: Int?
    }

    func testPDFKitOpensRealPDFProfilesAndMatchesKnownStructure() throws {
        let fixtures = try loadManifest().fixtures.filter { $0.format == "pdf" }
        let downloadDirectory = ReaderTestCorpus.downloadDirectory

        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: downloadDirectory.path),
            "Run scripts/download_test_corpus.sh first."
        )

        XCTAssertEqual(fixtures.count, 4)

        for fixture in fixtures {
            let fileURL = downloadDirectory.appending(path: fixture.fileName)
            let document = try XCTUnwrap(PDFDocument(url: fileURL), fixture.id)

            XCTAssertEqual(document.pageCount, fixture.expectedPageCount, fixture.id)
            XCTAssertNotNil(document.page(at: 0), fixture.id)

            let textCharacterCount = (0..<document.pageCount).reduce(into: 0) { count, pageIndex in
                count += document.page(at: pageIndex)?.string?.count ?? 0
            }
            XCTAssertEqual(textCharacterCount, fixture.expectedTextCharacters, fixture.id)
        }
    }

    func testPDFKitCanRenderFirstPageAsCoverForEveryPDFFixture() throws {
        let fixtures = try loadManifest().fixtures.filter { $0.format == "pdf" }
        let downloadDirectory = ReaderTestCorpus.downloadDirectory

        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: downloadDirectory.path),
            "Run scripts/download_test_corpus.sh first."
        )

        for fixture in fixtures {
            let fileURL = downloadDirectory.appending(path: fixture.fileName)
            let document = try XCTUnwrap(PDFDocument(url: fileURL), fixture.id)
            let page = try XCTUnwrap(document.page(at: 0), fixture.id)
            let thumbnail = page.thumbnail(of: CGSize(width: 320, height: 480), for: .cropBox)

            XCTAssertGreaterThan(thumbnail.size.width, 0, fixture.id)
            XCTAssertGreaterThan(thumbnail.size.height, 0, fixture.id)
        }
    }

    private func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: ReaderTestCorpus.manifestURL)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }
}

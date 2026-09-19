import Foundation
import XCTest
@testable import Reader

final class ReaderCatalogTests: XCTestCase {
    func testCatalogResultDecodesBackendContract() throws {
        let json = """
        {
          "source": "reader_catalog",
          "externalId": null,
          "workGroupId": 1342,
          "workId": 1342,
          "editionId": 1342,
          "title": "Pride and Prejudice",
          "subtitle": null,
          "authors": "Austen, Jane",
          "translators": "",
          "publisher": "Project Gutenberg",
          "releaseYear": 1813,
          "pageCount": 432,
          "description": "A novel.",
          "coverUrl": "https://www.gutenberg.org/cover.jpg",
          "primaryIdentifier": "gutenberg:1342",
          "availability": "read_now",
          "libraryPublicationId": null,
          "downloadUrl": "https://www.gutenberg.org/book.epub",
          "downloadMediaType": "application/epub+zip"
        }
        """

        let result = try JSONDecoder().decode(
            ReaderCatalogResult.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(result.id, "reader_catalog:1342")
        XCTAssertEqual(result.title, "Pride and Prejudice")
        XCTAssertEqual(result.byline, "Austen, Jane")
        XCTAssertEqual(result.availability, .readNow)
        XCTAssertEqual(result.availability.actionLabel, "read now")
        XCTAssertEqual(
            result.metadataLine,
            "Project Gutenberg · 1813 · 432 pages"
        )
        XCTAssertEqual(result.downloadUrl?.pathExtension, "epub")
    }

    func testCatalogResultUsesSafeFallbacksForSparseMetadata() throws {
        let result = ReaderCatalogResult(
            source: .readerCatalog,
            externalId: nil,
            workGroupId: 1,
            workId: nil,
            editionId: nil,
            title: "Untitled",
            subtitle: nil,
            authors: "",
            translators: "",
            publisher: nil,
            releaseYear: nil,
            pageCount: nil,
            description: nil,
            coverUrl: nil,
            primaryIdentifier: nil,
            availability: .addOwnFile,
            libraryPublicationId: nil,
            downloadUrl: nil,
            downloadMediaType: nil
        )

        XCTAssertEqual(result.byline, "unknown author")
        XCTAssertTrue(result.metadataLine.isEmpty)
        XCTAssertEqual(result.availability.actionLabel, "add your file")
    }

    func testCatalogResultDecodesThePreFallbackBackendContract() throws {
        let json = """
        {
          "workGroupId": 1342,
          "workId": 1342,
          "editionId": null,
          "title": "Pride and Prejudice",
          "subtitle": null,
          "authors": "Austen, Jane",
          "translators": "",
          "publisher": "Project Gutenberg",
          "releaseYear": 1813,
          "pageCount": null,
          "description": null,
          "coverUrl": null,
          "primaryIdentifier": "gutenberg:1342",
          "availability": "read_now",
          "libraryPublicationId": null,
          "downloadUrl": "https://www.gutenberg.org/book.epub",
          "downloadMediaType": "application/epub+zip"
        }
        """

        let result = try JSONDecoder().decode(
            ReaderCatalogResult.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(result.source)
        XCTAssertTrue(result.isCanonical)
        XCTAssertEqual(result.id, "reader_catalog:1342")
    }

    func testGoogleFallbackIsAttributedAndNotCanonical() {
        let result = ReaderCatalogResult(
            source: .googleBooks,
            externalId: "volume-id",
            workGroupId: nil,
            workId: nil,
            editionId: nil,
            title: "Recent Book",
            subtitle: nil,
            authors: "A. Writer",
            translators: "",
            publisher: "Test Press",
            releaseYear: 2026,
            pageCount: nil,
            description: nil,
            coverUrl: nil,
            primaryIdentifier: "isbn:9781234567890",
            availability: .notifyMe,
            libraryPublicationId: nil,
            downloadUrl: nil,
            downloadMediaType: nil
        )

        XCTAssertFalse(result.isCanonical)
        XCTAssertEqual(result.availability.actionLabel, "notify me")
        XCTAssertEqual(result.metadataLine, "Test Press · 2026 · Google Books")
    }
}

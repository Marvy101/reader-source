import AppKit
import Foundation
import XCTest
@testable import Reader

@MainActor
final class PDFAdapterCorpusTests: XCTestCase {
    func testPDFNoteMarkerChoosesTheNearestClearMargin() {
        let pageBounds = CGRect(x: 0, y: 0, width: 600, height: 800)

        let leftMarker = ReaderPDFMarginNoteAnnotation.defaultMarkerCenter(
            highlightBounds: CGRect(x: 55, y: 340, width: 220, height: 42),
            pageBounds: pageBounds
        )
        XCTAssertEqual(leftMarker.x, 20, accuracy: 0.001)

        let rightMarker = ReaderPDFMarginNoteAnnotation.defaultMarkerCenter(
            highlightBounds: CGRect(x: 320, y: 340, width: 225, height: 42),
            pageBounds: pageBounds
        )
        XCTAssertEqual(rightMarker.x, 580, accuracy: 0.001)
    }

    func testPDFNoteMarkerMovesFreelyAndReportsRelativePlacement() throws {
        let annotation = ReaderPDFMarginNoteAnnotation(
            annotationID: UUID(),
            highlightBounds: CGRect(x: 180, y: 340, width: 160, height: 42),
            pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800),
            defaultMarkerCenter: CGPoint(x: 586, y: 361),
            markerCenter: CGPoint(x: 586, y: 361),
            inkColor: .brown
        )

        let visiblePageBounds = CGRect(x: -380, y: -100, width: 1_350, height: 1_100)
        annotation.moveMarker(
            to: CGPoint(x: 72, y: 690),
            within: visiblePageBounds
        )

        XCTAssertEqual(annotation.markerCenter.x, 72, accuracy: 0.001)
        XCTAssertEqual(annotation.markerCenter.y, 690, accuracy: 0.001)
        XCTAssertEqual(
            annotation.placement.horizontalOffset,
            (72 - 586) / 600,
            accuracy: 0.001
        )
        XCTAssertEqual(
            annotation.placement.verticalOffset,
            (690 - 361) / 800,
            accuracy: 0.001
        )
        XCTAssertTrue(annotation.bounds.contains(annotation.markerCenter))
        XCTAssertTrue(annotation.bounds.intersects(CGRect(x: 180, y: 340, width: 1, height: 42)))
        XCTAssertEqual(annotation.paths?.count ?? 0, 0)
        XCTAssertEqual(annotation.markerBounds.width, annotation.markerBounds.height, accuracy: 0.001)

        annotation.moveMarker(
            to: CGPoint(x: -400, y: 1_100),
            within: visiblePageBounds
        )
        XCTAssertEqual(annotation.markerCenter.x, -380, accuracy: 0.001)
        XCTAssertEqual(annotation.markerCenter.y, 1_000, accuracy: 0.001)

        let restored = ReaderPDFMarginNoteAnnotation.restoredMarkerCenter(
            placement: annotation.placement,
            defaultMarkerCenter: CGPoint(x: 586, y: 361),
            pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800)
        )
        XCTAssertEqual(restored.x, annotation.markerCenter.x, accuracy: 0.001)
        XCTAssertEqual(restored.y, annotation.markerCenter.y, accuracy: 0.001)
    }

    func testPDFNoteInkUsesASofterDeeperCompanionColor() throws {
        let lemon = try XCTUnwrap(
            ReaderPDFMarginNoteAnnotation.noteInkColor(for: .lemon)
                .usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(lemon.redComponent, 154.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(lemon.greenComponent, 133.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(lemon.blueComponent, 21.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(lemon.alphaComponent, 0.68, accuracy: 0.001)
    }

    func testPDFAdapterFeedsTheSharedSearchIndexAndAnnotations() async throws {
        let sourceURL = ReaderTestCorpus.downloadDirectory.appending(
            path: "alice-wonderland-scan.pdf"
        )
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: sourceURL.path),
            "Run scripts/download_test_corpus.sh first."
        )

        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let reference = PublicationReference(
            sourceURL: sourceURL,
            format: .pdf,
            fingerprint: fingerprint,
            coverURL: nil
        )
        let adapter = try PDFKitReadingAdapter(reference: reference)
        let chunks = try adapter.textChunks()
        let index = ReaderTextIndex(
            publicationFingerprint: fingerprint,
            chunks: chunks
        )

        XCTAssertEqual(adapter.resourceCount, 110)
        XCTAssertEqual(chunks.count, adapter.resourceCount)
        let searchResults = index.search("Alice", limit: 3)
        let result = try XCTUnwrap(searchResults.first)
        XCTAssertTrue(result.locator.resourceID.hasPrefix("page-"))
        XCTAssertEqual(result.locator.publicationFingerprint, fingerprint)

        let resumeChunk = try XCTUnwrap(
            PDFKitReadingAdapter.resumeTextChunk(
                reference: reference,
                locator: ReaderLocator(
                    publicationFingerprint: fingerprint,
                    resourceID: "page-9",
                    position: 0,
                    progression: 9.0 / 109.0
                )
            )
        )
        XCTAssertEqual(resumeChunk.resourceID, "page-9")
        XCTAssertEqual(resumeChunk.ordinal, 9)

        adapter.display(searchResults: searchResults, activeIndex: 1)
        let highlightedSelections = try XCTUnwrap(adapter.pdfView.highlightedSelections)
        XCTAssertEqual(highlightedSelections.count, 3)
        XCTAssertNotEqual(
            highlightedSelections[0].color,
            highlightedSelections[1].color
        )

        adapter.display(searchResults: [], activeIndex: nil)
        XCTAssertEqual(adapter.pdfView.highlightedSelections?.count, 0)

        let document = try XCTUnwrap(adapter.pdfView.document)
        let pdfSelection = try XCTUnwrap(
            document.findString("Alice", withOptions: [.caseInsensitive]).first
        )
        adapter.pdfView.setCurrentSelection(pdfSelection, animate: false)

        let captured = await adapter.captureSelection()
        let readerSelection = try XCTUnwrap(captured)
        XCTAssertFalse(readerSelection.selectedText.isEmpty)
        XCTAssertFalse(readerSelection.locator.rectangles.isEmpty)

        let page = try XCTUnwrap(pdfSelection.pages.first)
        let annotationCount = page.annotations.count
        adapter.display(
            annotations: [
                ReaderAnnotation(
                    publicationFingerprint: fingerprint,
                    locator: readerSelection.locator,
                    selectedText: readerSelection.selectedText,
                    highlightColor: .petal
                )
            ]
        )
        XCTAssertEqual(page.annotations.count, annotationCount + 1)
        let renderedColor = try XCTUnwrap(page.annotations.last?.color.usingColorSpace(.deviceRGB))
        XCTAssertEqual(renderedColor.redComponent, ReaderHighlightColor.petal.red, accuracy: 0.01)
        XCTAssertEqual(renderedColor.greenComponent, ReaderHighlightColor.petal.green, accuracy: 0.01)
        XCTAssertEqual(renderedColor.blueComponent, ReaderHighlightColor.petal.blue, accuracy: 0.01)
        XCTAssertEqual(renderedColor.alphaComponent, 0.38, accuracy: 0.01)
    }

    func testFindNextNavigatesPDFViewToTheActiveMatchPage() throws {
        let sourceURL = ReaderTestCorpus.downloadDirectory.appending(
            path: "alice-wonderland-scan.pdf"
        )
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: sourceURL.path),
            "Run scripts/download_test_corpus.sh first."
        )

        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let session = try PublicationReaderSession(
            book: Book(
                title: "Alice's Adventures in Wonderland",
                author: "Lewis Carroll",
                progress: 0,
                coverStyle: .parchment,
                formatLabel: "PDF",
                readingLength: .pages(110),
                sample: ReadingSample(chapter: "", section: "", paragraphs: []),
                publication: PublicationReference(
                    sourceURL: sourceURL,
                    format: .pdf,
                    fingerprint: fingerprint,
                    coverURL: nil
                )
            )
        )
        guard case .pdf(let adapter) = session.backend else {
            return XCTFail("Expected the PDF adapter")
        }
        adapter.pdfView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)

        session.searchQuery = "Alice"
        session.search()
        let firstPage = try XCTUnwrap(session.searchResults.first?.locator.resourceID)
        let targetIndex = try XCTUnwrap(
            session.searchResults.firstIndex {
                $0.locator.resourceID != firstPage
            }
        )
        XCTAssertEqual(
            session.preferredInitialSearchResultIndex(
                in: session.searchResults,
                nearestTo: ReaderLocator(
                    publicationFingerprint: fingerprint,
                    resourceID: session.searchResults[targetIndex].locator.resourceID,
                    position: 0,
                    progression: 0
                )
            ),
            targetIndex
        )

        session.activeSearchResultIndex = targetIndex - 1
        session.moveSearchResult(by: 1)

        let expectedPage = Int(
            session.searchResults[targetIndex].locator.resourceID
                .dropFirst("page-".count)
        )
        XCTAssertEqual(session.activeSearchResultIndex, targetIndex)
        XCTAssertEqual(adapter.currentResourceIndex, expectedPage)
    }

}

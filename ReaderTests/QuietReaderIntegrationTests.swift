import AppKit
import PDFKit
import XCTest
@testable import Reader

@MainActor
final class QuietReaderIntegrationTests: XCTestCase {
    func testPDFNoteAddsAndRemovesMarginMarkerWithAnnotation() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "QuietReaderPDFNote-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appending(path: "margin-note.pdf")
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 400, height: 600))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 600).fill()
        ("A thought worth keeping" as NSString).draw(
            at: NSPoint(x: 40, y: 300),
            withAttributes: [.font: NSFont.systemFont(ofSize: 22)]
        )
        image.unlockFocus()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: pdfURL))

        let fingerprint = "pdf-margin-note"
        let adapter = try PDFKitReadingAdapter(
            reference: PublicationReference(
                sourceURL: pdfURL,
                format: .pdf,
                fingerprint: fingerprint,
                coverURL: nil
            )
        )
        let page = try XCTUnwrap(adapter.pdfView.document?.page(at: 0))
        let originalCount = page.annotations.count
        let annotationID = UUID()
        let locator = ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: "page-0",
            position: 0,
            progression: 0,
            rectangles: [
                ReaderRect(x: 40, y: 295, width: 215, height: 30)
            ]
        )

        adapter.display(
            annotations: [
                ReaderAnnotation(
                    id: annotationID,
                    publicationFingerprint: fingerprint,
                    locator: locator,
                    selectedText: "A thought worth keeping",
                    note: "Follow this thought later.",
                    highlightColor: .petal
                )
            ]
        )
        XCTAssertEqual(page.annotations.count, originalCount + 2)
        let marginAnnotation = try XCTUnwrap(
            page.annotations.last as? ReaderPDFMarginNoteAnnotation
        )
        XCTAssertLessThan(
            marginAnnotation.markerCenter.x,
            page.bounds(for: .cropBox).midX,
            "A left-side selection should keep its note marker in the left margin."
        )
        let markerColor = try XCTUnwrap(marginAnnotation.color.usingColorSpace(.deviceRGB))
        XCTAssertEqual(markerColor.redComponent, 169.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(markerColor.greenComponent, 79.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(markerColor.blueComponent, 89.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(markerColor.alphaComponent, 0.68, accuracy: 0.01)

        adapter.display(
            annotations: [
                ReaderAnnotation(
                    id: annotationID,
                    publicationFingerprint: fingerprint,
                    locator: locator,
                    selectedText: "A thought worth keeping",
                    note: nil,
                    highlightColor: .petal
                )
            ]
        )
        XCTAssertEqual(page.annotations.count, originalCount + 1)
    }

    func testPDFReaderUsesSeamlessVerticalContinuousLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "QuietReaderPDFLayout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appending(path: "continuous.pdf")
        let document = PDFDocument()
        for pageNumber in 1...2 {
            let image = NSImage(size: NSSize(width: 400, height: 600))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 400, height: 600).fill()
            ("Page \(pageNumber)" as NSString).draw(
                at: NSPoint(x: 40, y: 300),
                withAttributes: [.font: NSFont.systemFont(ofSize: 22)]
            )
            image.unlockFocus()
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: pageNumber - 1)
        }
        XCTAssertTrue(document.write(to: pdfURL))

        let adapter = try PDFKitReadingAdapter(
            reference: PublicationReference(
                sourceURL: pdfURL,
                format: .pdf,
                fingerprint: "continuous-layout",
                coverURL: nil
            )
        )

        XCTAssertEqual(adapter.pdfView.displayMode, .singlePageContinuous)
        XCTAssertEqual(adapter.pdfView.displayDirection, .vertical)
        XCTAssertFalse(adapter.pdfView.displaysPageBreaks)
        XCTAssertEqual(adapter.pdfView.pageBreakMargins.top, 0)
        XCTAssertEqual(adapter.pdfView.pageBreakMargins.left, 0)
        XCTAssertEqual(adapter.pdfView.pageBreakMargins.bottom, 0)
        XCTAssertEqual(adapter.pdfView.pageBreakMargins.right, 0)
        XCTAssertFalse(adapter.pdfView.pageShadowsEnabled)
    }

    func testQuietPreferencesAndFilterSurviveRecreation() throws {
        let suite = "QuietReaderIntegrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var first: QuietReaderState? = QuietReaderState(defaults: defaults)
        first?.filter = .papers
        first?.preferences.size = 27
        first?.preferences.serif = true
        first?.preferences.theme = .dark
        first = nil

        let restored = QuietReaderState(defaults: defaults)
        XCTAssertEqual(restored.filter, .papers)
        XCTAssertEqual(restored.preferences.size, 27)
        XCTAssertTrue(restored.preferences.serif)
        XCTAssertEqual(restored.preferences.theme, .dark)
    }

    func testMultipleRealFileTypesImportAndSearchTogether() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "QuietReaderImports-\(UUID().uuidString)")
        let incoming = root.appending(path: "Incoming", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let textURL = incoming.appending(path: "sea-notes.txt")
        try Data("The hardest thing of all to see is what is really there.".utf8)
            .write(to: textURL)

        let pdfURL = incoming.appending(path: "attention.pdf")
        let pdf = PDFDocument()
        let image = NSImage(size: NSSize(width: 400, height: 600))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 600).fill()
        ("Attention is all you need" as NSString).draw(
            at: NSPoint(x: 40, y: 300),
            withAttributes: [.font: NSFont.systemFont(ofSize: 22)]
        )
        image.unlockFocus()
        pdf.insert(PDFPage(image: image)!, at: 0)
        XCTAssertTrue(pdf.write(to: pdfURL))

        let store = try ReaderLibraryStore(rootURL: root.appending(path: "Library"))
        let model = try LibraryModel(store: store)
        let imported = model.importFiles([textURL, pdfURL])

        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(Set(imported.map(\.formatLabel)), Set(["TXT", "PDF"]))
        XCTAssertEqual(model.books(for: .papers).count, 1)
        XCTAssertFalse(model.searchAll("hardest").isEmpty)
        XCTAssertTrue(
            imported.compactMap { $0.publication?.coverURL }.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            }
        )
    }
}

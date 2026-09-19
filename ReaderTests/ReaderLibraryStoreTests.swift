import Foundation
import XCTest
@testable import Reader

final class ReaderLibraryStoreTests: XCTestCase {
    func testLegacyHighlightColorNamesMapToFinalPalette() {
        XCTAssertEqual(ReaderHighlightColor(persistedValue: "sun"), .lemon)
        XCTAssertEqual(ReaderHighlightColor(persistedValue: "rose"), .petal)
        XCTAssertEqual(ReaderHighlightColor(persistedValue: "tide"), .aqua)
        XCTAssertEqual(ReaderHighlightColor(persistedValue: "lemon"), .lemon)
    }

    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ReaderLibraryStoreTests-(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot,
           FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    @MainActor
    func testMigrationCreatesExplicitLocalTables() throws {
        let store = try ReaderLibraryStore(rootURL: temporaryRoot)

        XCTAssertTrue(
            try store.tableNames().isSuperset(of: [
                "publications",
                "reading_state",
                "annotations",
                "device_reader_preferences",
                "conversations"
            ])
        )
    }

    @MainActor
    func testLibraryReadingStateAnnotationsAndPreferencesSurviveReopen() throws {
        let book = try makeManagedBook()
        var store: ReaderLibraryStore? = try ReaderLibraryStore(rootURL: temporaryRoot)
        try store?.saveImportedBook(book)

        let locator = ReaderLocator(
            publicationFingerprint: "fixture-fingerprint",
            resourceID: "chapter-4",
            position: 812,
            progression: 0.42,
            textAnchor: TextAnchor(
                exact: "Call me Ishmael.",
                prefix: "",
                suffix: " Some years ago"
            )
        )
        try store?.saveReadingState(
            publicationID: book.id,
            locator: locator,
            progress: 0.37
        )
        let annotation = ReaderAnnotation(
            publicationFingerprint: "fixture-fingerprint",
            locator: locator,
            selectedText: "Call me Ishmael.",
            note: "the opening stays strange",
            notePlacement: ReaderNotePlacement(
                horizontalOffset: -0.24,
                verticalOffset: 0.18
            ),
            highlightColor: .aqua
        )
        try store?.saveAnnotation(annotation, publicationID: book.id)
        let conversation = ReaderConversation(
            publicationID: book.id,
            publicationTitle: book.title,
            question: "why this opening?",
            answer: "It makes identity sound chosen.",
            locator: locator
        )
        try store?.saveConversation(conversation)
        try store?.saveDevicePreferences(
            DeviceReaderPreferences(
                scale: 1.24,
                pdfScaleMode: "fitWidth"
            ),
            publicationID: book.id
        )
        store = nil

        let reopened = try ReaderLibraryStore(rootURL: temporaryRoot)
        let restoredBook = try XCTUnwrap(reopened.loadBooks().first)
        let restoredState = try XCTUnwrap(
            reopened.loadReadingState(publicationID: book.id)
        )
        let restoredAnnotation = try XCTUnwrap(
            reopened.loadAnnotations(publicationID: book.id).first
        )
        let restoredPreferences = try XCTUnwrap(
            reopened.loadDevicePreferences(publicationID: book.id)
        )
        let restoredConversation = try XCTUnwrap(
            reopened.loadConversations().first
        )

        XCTAssertEqual(restoredBook.id, book.id)
        XCTAssertEqual(restoredBook.title, "Moby-Dick")
        XCTAssertEqual(restoredBook.progress, 0.37, accuracy: 0.0001)
        XCTAssertEqual(restoredState.locator, locator)
        XCTAssertEqual(restoredAnnotation.id, annotation.id)
        XCTAssertEqual(
            restoredAnnotation.publicationFingerprint,
            annotation.publicationFingerprint
        )
        XCTAssertEqual(restoredAnnotation.locator, annotation.locator)
        XCTAssertEqual(restoredAnnotation.selectedText, annotation.selectedText)
        XCTAssertEqual(restoredAnnotation.note, annotation.note)
        XCTAssertEqual(restoredAnnotation.notePlacement, annotation.notePlacement)
        XCTAssertEqual(restoredAnnotation.highlightColor, .aqua)
        XCTAssertEqual(
            restoredAnnotation.createdAt.timeIntervalSince1970,
            annotation.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            restoredAnnotation.updatedAt.timeIntervalSince1970,
            annotation.updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(restoredPreferences.scale, 1.24, accuracy: 0.0001)
        XCTAssertEqual(restoredPreferences.pdfScaleMode, "fitWidth")
        XCTAssertEqual(restoredConversation.id, conversation.id)
        XCTAssertEqual(restoredConversation.publicationID, conversation.publicationID)
        XCTAssertEqual(restoredConversation.publicationTitle, conversation.publicationTitle)
        XCTAssertEqual(restoredConversation.question, conversation.question)
        XCTAssertEqual(restoredConversation.answer, conversation.answer)
        XCTAssertEqual(restoredConversation.locator, conversation.locator)
        XCTAssertEqual(
            restoredConversation.createdAt.timeIntervalSince1970,
            conversation.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        let reloadedModel = try LibraryModel(store: reopened)
        XCTAssertEqual(
            reloadedModel.searchAll("opening stays strange").first?.text,
            "the opening stays strange"
        )
    }

    @MainActor
    func testCustomBookOrderSurvivesReopen() throws {
        let first = try makeManagedBook(title: "First", fingerprint: "first")
        let second = try makeManagedBook(title: "Second", fingerprint: "second")
        let third = try makeManagedBook(title: "Third", fingerprint: "third")
        var store: ReaderLibraryStore? = try ReaderLibraryStore(rootURL: temporaryRoot)
        try store?.saveImportedBook(first)
        try store?.saveImportedBook(second)
        try store?.saveImportedBook(third)

        try store?.saveBookOrder([third.id, first.id, second.id])
        store = nil

        let reopened = try ReaderLibraryStore(rootURL: temporaryRoot)
        XCTAssertEqual(
            try reopened.loadBooks().map(\.title),
            ["Third", "First", "Second"]
        )
    }

    @MainActor
    func testSyncedAnnotationMergesOnlyWhenRemoteRecordIsNewer() throws {
        let book = try makeManagedBook()
        let store = try ReaderLibraryStore(rootURL: temporaryRoot)
        try store.saveImportedBook(book)
        let fingerprint = try XCTUnwrap(book.publication?.fingerprint)
        let locator = ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: "text",
            position: 0,
            progression: 0
        )
        let id = UUID()
        let local = ReaderAnnotation(
            id: id,
            publicationFingerprint: fingerprint,
            locator: locator,
            selectedText: "Call me Ishmael.",
            note: "local",
            notePlacement: ReaderNotePlacement(
                horizontalOffset: -0.3,
                verticalOffset: 0.2
            ),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        try store.saveAnnotation(local, publicationID: book.id)

        try store.mergeSyncedAnnotations([
            ReaderAnnotation(
                id: id,
                publicationFingerprint: fingerprint,
                locator: locator,
                selectedText: local.selectedText,
                note: "stale remote",
                createdAt: local.createdAt,
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        ])
        XCTAssertEqual(try store.loadAnnotations(publicationID: book.id).first?.note, "local")

        try store.mergeSyncedAnnotations([
            ReaderAnnotation(
                id: id,
                publicationFingerprint: fingerprint,
                locator: locator,
                selectedText: local.selectedText,
                note: "new remote",
                highlightColor: .petal,
                createdAt: local.createdAt,
                updatedAt: Date(timeIntervalSince1970: 40)
            )
        ])
        let merged = try XCTUnwrap(store.loadAnnotations(publicationID: book.id).first)
        XCTAssertEqual(merged.note, "new remote")
        XCTAssertEqual(merged.highlightColor, .petal)
        XCTAssertEqual(merged.notePlacement, local.notePlacement)
        XCTAssertEqual(merged.updatedAt, Date(timeIntervalSince1970: 40))
    }

    @MainActor
    func testSyncedReadingStateMergesOnlyWhenRemoteRecordIsNewer() throws {
        let book = try makeManagedBook()
        let store = try ReaderLibraryStore(rootURL: temporaryRoot)
        try store.saveImportedBook(book, importedAt: Date(timeIntervalSince1970: 1))
        let fingerprint = try XCTUnwrap(book.publication?.fingerprint)
        let localLocator = ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: "page-3",
            position: 2,
            progression: 0
        )
        try store.saveReadingState(
            publicationID: book.id,
            locator: localLocator,
            progress: 0.2,
            openedAt: Date(timeIntervalSince1970: 30)
        )

        let stale = StoredReadingRecord(
            publicationID: book.id,
            state: StoredReadingState(
                locator: ReaderLocator(
                    publicationFingerprint: fingerprint,
                    resourceID: "page-2",
                    position: 1,
                    progression: 0
                ),
                progress: 0.1,
                lastOpenedAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        )
        XCTAssertTrue(try store.mergeSyncedReadingRecords([stale]).isEmpty)
        XCTAssertEqual(
            try store.loadReadingState(publicationID: book.id)?.locator,
            localLocator
        )

        let remoteLocator = ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: "page-8",
            position: 7,
            progression: 0
        )
        let newer = StoredReadingRecord(
            publicationID: book.id,
            state: StoredReadingState(
                locator: remoteLocator,
                progress: 0.7,
                lastOpenedAt: Date(timeIntervalSince1970: 40),
                updatedAt: Date(timeIntervalSince1970: 40)
            )
        )
        XCTAssertEqual(try store.mergeSyncedReadingRecords([newer]), [newer])
        let merged = try XCTUnwrap(store.loadReadingState(publicationID: book.id))
        XCTAssertEqual(merged.locator, remoteLocator)
        XCTAssertEqual(merged.progress, 0.7, accuracy: 0.0001)
        XCTAssertEqual(try store.loadAllReadingRecords().map(\.publicationID), [book.id])
    }

    @MainActor
    func testRealEPUBAndPDFImportsSurviveLibraryReload() throws {
        let corpus = ReaderTestCorpus.downloadDirectory
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: corpus.path),
            "Run scripts/download_test_corpus.sh first."
        )

        let store = try ReaderLibraryStore(rootURL: temporaryRoot)
        let model = try LibraryModel(store: store)
        let imported = model.importFiles([
            corpus.appending(path: "moby-dick.epub"),
            corpus.appending(path: "gutenberg-history-digital.pdf")
        ])

        XCTAssertEqual(imported.count, 2)
        XCTAssertTrue(
            imported.allSatisfy {
                guard let url = $0.publication?.sourceURL else { return false }
                return url.path.hasPrefix(temporaryRoot.path)
                    && FileManager.default.fileExists(atPath: url.path)
            }
        )

        let importedPDF = try XCTUnwrap(
            imported.first { $0.publication?.format == .pdf }
        )
        let fingerprint = try XCTUnwrap(
            importedPDF.publication?.fingerprint
        )
        try store.saveReadingState(
            publicationID: importedPDF.id,
            locator: ReaderLocator(
                publicationFingerprint: fingerprint,
                resourceID: "page-2",
                position: 2,
                progression: 0.25
            ),
            progress: 0.25
        )
        try store.saveDevicePreferences(
            DeviceReaderPreferences(scale: 1.24),
            publicationID: importedPDF.id
        )

        let reopenedStore = try ReaderLibraryStore(rootURL: temporaryRoot)
        let reloadedModel = try LibraryModel(store: reopenedStore)
        XCTAssertEqual(reloadedModel.books.count, 2)
        XCTAssertTrue(reloadedModel.hasResumeBook)
        XCTAssertEqual(
            Set(reloadedModel.books.map(\.formatLabel)),
            Set(["EPUB", "PDF"])
        )

        let resumeSnapshot = try XCTUnwrap(reloadedModel.resumeSnapshot())
        XCTAssertEqual(resumeSnapshot.book.id, importedPDF.id)
        XCTAssertFalse(resumeSnapshot.sentence.isEmpty)

        let restoredPDF = try XCTUnwrap(
            reloadedModel.books.first { $0.id == importedPDF.id }
        )
        let session = try reloadedModel.makeReaderSession(for: restoredPDF)
        XCTAssertEqual(session.resourceIndex, 2)
        XCTAssertEqual(session.textScale, 1.24, accuracy: 0.0001)
    }

    @MainActor
    func testLibraryAdoptsManagedFilesFromBeforeDatabaseMigration() throws {
        let importDirectory = temporaryRoot
            .appending(path: "Imports", directoryHint: .isDirectory)
            .appending(path: "legacy-folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: importDirectory,
            withIntermediateDirectories: true
        )
        try Data("A previously imported book.".utf8).write(
            to: importDirectory.appending(path: "old-book.txt")
        )

        let model = try LibraryModel(
            store: ReaderLibraryStore(rootURL: temporaryRoot)
        )

        XCTAssertEqual(model.books.count, 1)
        XCTAssertEqual(model.books.first?.title, "old-book")
        XCTAssertEqual(model.books.first?.formatLabel, "TXT")
    }

    private func makeManagedBook(
        title: String = "Moby-Dick",
        fingerprint: String = "fixture-fingerprint"
    ) throws -> Book {
        let directory = temporaryRoot
            .appending(path: "Imports", directoryHint: .isDirectory)
            .appending(path: fingerprint, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let sourceURL = directory.appending(path: "\(fingerprint).txt")
        try Data("Call me Ishmael.".utf8).write(to: sourceURL)

        return Book(
            title: title,
            author: "Herman Melville",
            progress: 0,
            coverStyle: .sea,
            formatLabel: "TXT",
            readingLength: .reflowable,
            sample: ReadingSample(
                chapter: "Plain text",
                section: "Reflowable text",
                paragraphs: []
            ),
            publication: PublicationReference(
                sourceURL: sourceURL,
                format: .plainText,
                fingerprint: fingerprint,
                coverURL: nil
            )
        )
    }
}

import XCTest
@testable import Reader

@MainActor
final class LibraryModelTests: XCTestCase {
    func testReorderingBookMovesItToDroppedBooksPosition() throws {
        let model = LibraryModel(books: testBooks)
        let first = try XCTUnwrap(model.books.first)
        let third = try XCTUnwrap(model.books.dropFirst(2).first)

        model.reorder(first, to: third)

        XCTAssertEqual(
            model.books.map(\.title),
            ["Second Book", "Third Book", "First Book", "Finished Book"]
        )
    }

    func testSearchMatchesTitleAndAuthorCaseInsensitively() {
        let model = LibraryModel(books: testBooks)

        model.searchText = "second"
        XCTAssertEqual(model.filteredBooks.map(\.title), ["Second Book"])

        model.searchText = "AUTHOR C"
        XCTAssertEqual(model.filteredBooks.map(\.title), ["Third Book"])
    }

    func testCurrentBookUsesMostAdvancedUnfinishedBook() {
        let model = LibraryModel(books: testBooks)

        XCTAssertEqual(model.currentBook?.title, "Third Book")
    }

    func testReadingNowOnlyShowsStartedUnfinishedBooks() {
        let model = LibraryModel(
            books: testBooks,
            destination: .readingNow
        )

        XCTAssertEqual(
            Set(model.filteredBooks.map(\.title)),
            Set(["First Book", "Second Book", "Third Book"])
        )
    }

    func testOpeningAndClosingReaderUpdatesNavigationState() {
        let model = LibraryModel(books: testBooks)
        let book = try! XCTUnwrap(model.books.first)

        model.open(book)
        XCTAssertEqual(model.openBook, book)

        model.closeReader()
        XCTAssertNil(model.openBook)
    }

    func testLibraryWithoutStoredReadingPositionHasNoResumeBook() {
        let model = LibraryModel(books: testBooks)

        XCTAssertFalse(model.hasResumeBook)
    }

    func testCreatingReaderSessionPublishesBookKnowledgeForPreparation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReaderBookOpen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "book.txt")
        try "The White Rabbit ran close by Alice.".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let book = Book(
            title: "Alice",
            author: "Lewis Carroll",
            progress: 0,
            coverStyle: .night,
            formatLabel: "TXT",
            readingLength: .reflowable,
            sample: ReadingSample(chapter: "", section: "", paragraphs: []),
            publication: PublicationReference(
                sourceURL: sourceURL,
                format: .plainText,
                fingerprint: "alice-fingerprint",
                coverURL: nil
            )
        )
        let model = LibraryModel(books: [book])
        var prepared: ReaderBookKnowledgeSnapshot?
        model.onBookKnowledgeAvailable = { prepared = $0 }

        let session = try model.makeReaderSession(for: book)

        XCTAssertEqual(prepared?.publicationID, book.id)
        XCTAssertEqual(prepared?.chunks.first?.resourceId, "text")
        XCTAssertTrue(prepared?.chunks.first?.text.contains("White Rabbit") == true)

        let selection = ReaderSelection(
            locator: ReaderLocator(
                publicationFingerprint: "alice-fingerprint",
                resourceID: "text",
                position: 4,
                progression: 0.25
            ),
            selectedText: "White Rabbit"
        )
        _ = session.createHighlight(selection, note: "follow this")

        XCTAssertEqual(prepared?.annotations.count, 1)
        XCTAssertEqual(prepared?.annotations.first?.note, "follow this")
    }

    func testImportPublishesBookBeforeOpeningIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReaderImmediateImport-\(UUID().uuidString)")
        let library = directory.appending(path: "Library")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "book.txt")
        try "A book ready for immediate indexing.".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let store = try ReaderLibraryStore(rootURL: library)
        let model = try LibraryModel(store: store)
        var published: Book?
        model.onBookImported = { published = $0 }

        let imported = model.importFiles([sourceURL])

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(published?.id, imported.first?.id)
        XCTAssertEqual(model.openBook?.id, imported.first?.id)
    }

    func testAuthenticatedReconciliationBackfillsEveryExistingBook() async throws {
        let fixture = try makeCloudSyncFixture(bookCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = cloudSyncSession()
        let backend = CloudSyncBackendStub(session: session)
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: CloudSyncCredentialStore(session: session)
        )
        let model = LibraryModel(books: fixture.books)

        await model.reconcileCloudLibrary(using: account)

        let fileSyncs = await backend.fileSyncs
        let ingestions = await backend.ingestions
        XCTAssertEqual(Set(fileSyncs.map(\.publicationID)), Set(fixture.books.map(\.id)))
        XCTAssertEqual(Set(ingestions), Set(fixture.books.map(\.id)))
        XCTAssertEqual(model.cloudSyncMessage, "2 books synced just now")
        for book in fixture.books {
            guard case .synced = model.cloudBookSyncStates[book.id] else {
                return XCTFail("Expected \(book.title) to be marked synced")
            }
        }
    }

    func testFailedCloudBookRetriesUntilBothPathsAreReady() async throws {
        let fixture = try makeCloudSyncFixture(bookCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = cloudSyncSession()
        let backend = CloudSyncBackendStub(
            session: session,
            fileFailuresRemaining: 1
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: CloudSyncCredentialStore(session: session)
        )
        let model = LibraryModel(books: fixture.books)

        await model.reconcileCloudLibrary(using: account)

        XCTAssertEqual(model.cloudSyncMessage, "0 of 1 synced · 1 book will retry")
        guard case .failed = model.cloudBookSyncStates[fixture.books[0].id] else {
            return XCTFail("Expected the first attempt to remain retryable")
        }

        await model.reconcileCloudLibrary(using: account)

        let fileAttempts = await backend.fileSyncAttempts
        let ingestionCount = await backend.ingestions.count
        XCTAssertEqual(fileAttempts, 2)
        XCTAssertEqual(ingestionCount, 2)
        XCTAssertEqual(model.cloudSyncMessage, "1 book synced just now")
    }

    func testLifecycleReconciliationAlwaysRechecksRemoteState() async throws {
        let fixture = try makeCloudSyncFixture(bookCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = cloudSyncSession()
        let backend = CloudSyncBackendStub(session: session)
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: CloudSyncCredentialStore(session: session)
        )
        let model = LibraryModel(books: fixture.books)

        await model.reconcileCloudLibrary(using: account)
        await model.reconcileCloudLibrary(using: account)

        let fileAttempts = await backend.fileSyncAttempts
        let ingestionCount = await backend.ingestions.count
        XCTAssertEqual(fileAttempts, 2)
        XCTAssertEqual(ingestionCount, 2)
        XCTAssertEqual(model.cloudSyncMessage, "1 book synced just now")
    }

    func testNewlyCreatedAccountCanReconcileItsLocalLibrary() async throws {
        let fixture = try makeCloudSyncFixture(bookCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = cloudSyncSession()
        let backend = CloudSyncBackendStub(session: session)
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: CloudSyncCredentialStore()
        )
        let model = LibraryModel(books: fixture.books)

        await model.reconcileCloudLibrary(using: account)
        let uploadsBeforeSignUp = await backend.fileSyncs
        XCTAssertTrue(uploadsBeforeSignUp.isEmpty)

        await account.signUp(
            name: "New Reader",
            email: "new-reader@example.com",
            password: "password"
        )
        await model.reconcileCloudLibrary(using: account)

        let uploadsAfterSignUp = await backend.fileSyncs
        let ingestionsAfterSignUp = await backend.ingestions
        XCTAssertTrue(account.isAuthenticated)
        XCTAssertEqual(uploadsAfterSignUp.count, 1)
        XCTAssertEqual(ingestionsAfterSignUp.count, 1)
        XCTAssertEqual(model.cloudSyncMessage, "1 book synced just now")
    }

    func testBookProgressIsClamped() {
        let overComplete = Book(
            title: "Test",
            author: "Author",
            progress: 2,
            coverStyle: .night,
            formatLabel: "TXT",
            readingLength: .reflowable,
            sample: ReadingSample(chapter: "", section: "", paragraphs: [])
        )

        XCTAssertEqual(overComplete.progress, 1)
    }

    func testLibraryMetadataUsesTruthfulFormatSpecificLength() {
        let singlePage = makeBook(readingLength: .pages(1), formatLabel: "PDF")
        let longPDF = makeBook(readingLength: .pages(204), formatLabel: "PDF")
        let epub = makeBook(
            readingLength: .estimatedPages(16),
            formatLabel: "EPUB"
        )
        let text = makeBook(readingLength: .reflowable, formatLabel: "TXT")

        XCTAssertEqual(singlePage.libraryMetadataLabel, "1 page · PDF")
        XCTAssertEqual(longPDF.libraryMetadataLabel, "204 pages · PDF")
        XCTAssertEqual(epub.libraryMetadataLabel, "≈ 16 pages · EPUB")
        XCTAssertEqual(text.libraryMetadataLabel, "Reflowable · TXT")
    }

    private var testBooks: [Book] {
        [
            makeBook(title: "First Book", author: "Author A", progress: 0.2),
            makeBook(title: "Second Book", author: "Author B", progress: 0.4),
            makeBook(title: "Third Book", author: "Author C", progress: 0.8),
            makeBook(title: "Finished Book", author: "Author D", progress: 1)
        ]
    }

    private func makeBook(
        title: String = "Test Book",
        author: String = "Test Author",
        progress: Double = 0,
        readingLength: ReadingLength = .reflowable,
        formatLabel: String = "TXT"
    ) -> Book {
        Book(
            title: title,
            author: author,
            progress: progress,
            coverStyle: .night,
            formatLabel: formatLabel,
            readingLength: readingLength,
            sample: ReadingSample(chapter: "", section: "", paragraphs: [])
        )
    }

    private func makeCloudSyncFixture(
        bookCount: Int
    ) throws -> (root: URL, books: [Book]) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ReaderCloudSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let books = try (0..<bookCount).map { index in
            let sourceURL = root.appending(path: "book-\(index).txt")
            try "Book \(index) has searchable text.".write(
                to: sourceURL,
                atomically: true,
                encoding: .utf8
            )
            return Book(
                title: "Cloud Book \(index)",
                author: "Reader",
                progress: 0,
                coverStyle: .night,
                formatLabel: "TXT",
                readingLength: .reflowable,
                sample: ReadingSample(chapter: "", section: "", paragraphs: []),
                publication: PublicationReference(
                    sourceURL: sourceURL,
                    format: .plainText,
                    fingerprint: String(repeating: "\(index + 1)", count: 64),
                    coverURL: nil
                )
            )
        }
        return (root, books)
    }

    private func cloudSyncSession() -> ReaderAuthSession {
        ReaderAuthSession(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: 4_000_000_000,
            user: ReaderAuthUser(id: "cloud-reader", email: "reader@example.com")
        )
    }
}

private final class CloudSyncCredentialStore: ReaderCredentialStoring, @unchecked Sendable {
    private var session: ReaderAuthSession?

    init(session: ReaderAuthSession? = nil) {
        self.session = session
    }

    func load() throws -> ReaderAuthSession? { session }
    func save(_ session: ReaderAuthSession) throws { self.session = session }
    func remove() throws { session = nil }
}

private actor CloudSyncBackendStub: ReaderBackendServicing {
    let session: ReaderAuthSession
    private(set) var fileSyncs: [ReaderLibraryFileUpload] = []
    private(set) var ingestions: [UUID] = []
    private(set) var fileSyncAttempts = 0
    private var fileFailuresRemaining: Int

    init(
        session: ReaderAuthSession,
        fileFailuresRemaining: Int = 0
    ) {
        self.session = session
        self.fileFailuresRemaining = fileFailuresRemaining
    }

    func signIn(email: String, password: String) async throws -> ReaderAuthSession {
        session
    }

    func signUp(email: String, password: String) async throws -> ReaderSignUpResult {
        ReaderSignUpResult(
            session: session,
            user: session.user,
            requiresEmailConfirmation: false
        )
    }

    func refreshSession(refreshToken: String) async throws -> ReaderAuthSession {
        session
    }

    func answerHighlightQuestion(
        _ request: HighlightQuestionRequest,
        accessToken: String
    ) async throws -> HighlightQuestionAnswer {
        HighlightQuestionAnswer(text: "Answer", model: "test")
    }

    func libraryOrganization(
        accessToken: String
    ) async throws -> ReaderLibraryOrganization {
        .empty
    }

    func streamChat(
        _ request: ReaderChatRequest,
        accessToken: String
    ) async throws -> AsyncThrowingStream<ReaderChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func generateChatTitle(
        _ request: ReaderChatTitleRequest,
        accessToken: String
    ) async throws -> ReaderChatTitle {
        ReaderChatTitle(title: "Conversation", model: "test")
    }

    func ingestBookKnowledge(
        _ request: ReaderBookKnowledgeIngestionRequest,
        accessToken: String
    ) async throws {
        ingestions.append(request.publicationID)
    }

    func syncLibraryFile(
        _ upload: ReaderLibraryFileUpload,
        accessToken: String
    ) async throws {
        fileSyncAttempts += 1
        if fileFailuresRemaining > 0 {
            fileFailuresRemaining -= 1
            throw ReaderBackendError.serviceUnavailable
        }
        fileSyncs.append(upload)
    }
}

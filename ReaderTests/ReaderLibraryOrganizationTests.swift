import XCTest
#if os(macOS)
import AppKit
#endif
@testable import Reader

@MainActor
final class ReaderLibraryOrganizationTests: XCTestCase {
    func testBookDragProviderCarriesNativeTextAndTypedBookPayload() async throws {
        let bookID = UUID()
        let provider = QuietLibraryDrag.provider(for: bookID)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.text"))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(QuietLibraryDrag.type.identifier))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: QuietLibraryDrag.type.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), bookID.uuidString)
    }

    func testOrdinaryTextDoesNotAdvertiseBookMoveType() {
        let provider = NSItemProvider(object: UUID().uuidString as NSString)
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(QuietLibraryDrag.type.identifier))
    }

#if os(macOS)
    func testNativeBookDragCarriesTheSameTypedIDAsDropTargets() {
        let id = UUID()
        let item = LibraryBookDragSource.SourceView.pasteboardItem(for: id)
        XCTAssertEqual(item.string(forType: .string), id.uuidString)
        let type = NSPasteboard.PasteboardType(QuietLibraryDrag.type.identifier)
        XCTAssertEqual(item.data(forType: type), Data(id.uuidString.utf8))
    }
#endif

    func testNestedFoldersBecomeSimpleBreadcrumbOptions() {
        let parentID = UUID()
        let childID = UUID()
        let folders = [
            ReaderLibraryFolder(id: childID, parentID: parentID, name: "papers"),
            ReaderLibraryFolder(id: parentID, name: "research")
        ]

        XCTAssertEqual(
            folders.libraryOptions.map(\.title),
            ["research", "research / papers"]
        )
    }

    func testLibraryPreviewStartsWithoutDefaultLibraries() {
        let model = LibraryModel(books: [makeBook(title: "First", fingerprint: "first")])

        model.installLibraryPreview()

        XCTAssertTrue(model.libraryOptions.isEmpty)
    }

    func testSelectingLibraryFiltersLocalBooksBySyncedFingerprint() async throws {
        let first = makeBook(title: "First", fingerprint: "first")
        let second = makeBook(title: "Second", fingerprint: "second")
        let model = LibraryModel(books: [first, second])
        model.installLibraryPreview()
        let account = ReaderAccountModel(
            backend: LibraryBackendStub(),
            credentialStore: LibraryCredentialStoreStub()
        )
        let fiction = try await model.createLibrary(named: "fiction", using: account)
        try await model.move(first, to: fiction.id, using: account)

        XCTAssertEqual(
            model.books(for: .everything, in: fiction.id).map(\.title),
            ["First"]
        )
        XCTAssertEqual(
            model.books(for: .everything, in: nil).map(\.title),
            ["First", "Second"]
        )
    }

    func testMovingBookUpdatesSelectedLibraryImmediately() async throws {
        let book = makeBook(title: "First", fingerprint: "first")
        let model = LibraryModel(books: [book])
        model.installLibraryPreview()
        let account = ReaderAccountModel(
            backend: LibraryBackendStub(),
            credentialStore: LibraryCredentialStoreStub()
        )
        let work = try await model.createLibrary(named: "work", using: account)

        try await model.move(book, to: work.id, using: account)

        XCTAssertEqual(model.libraryID(for: book), work.id)
        XCTAssertEqual(
            model.books(for: .everything, in: work.id).map(\.title),
            ["First"]
        )
    }

    func testFolderRenameAndDeleteStayInSyncWithBackend() async throws {
        let folderID = UUID()
        let backend = LibraryBackendStub(
            organization: ReaderLibraryOrganization(
                folders: [ReaderLibraryFolder(id: folderID, name: "essays")],
                files: []
            )
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: LibraryCredentialStoreStub(session: makeSession())
        )
        let model = LibraryModel(books: [])
        await model.synchronizeLibraries(using: account)

        let renamed = try await model.renameLibrary(
            folderID,
            to: "long reads",
            using: account
        )
        XCTAssertEqual(renamed.name, "long reads")
        XCTAssertEqual(model.libraryOptions.map(\.title), ["long reads"])
        let backendRename = await backend.lastRename
        XCTAssertEqual(backendRename?.id, folderID)
        XCTAssertEqual(backendRename?.name, "long reads")

        model.selectedLibraryID = folderID
        try await model.deleteLibrary(folderID, using: account)
        XCTAssertTrue(model.libraryOptions.isEmpty)
        XCTAssertNil(model.selectedLibraryID)
        let deletedID = await backend.deletedLibraryID
        XCTAssertEqual(deletedID, folderID)
    }

    func testDeleteRejectsNonEmptyLibraryBeforeBackendMutation() async throws {
        let book = makeBook(title: "First", fingerprint: "first")
        let model = LibraryModel(books: [book])
        model.installLibraryPreview()
        let account = ReaderAccountModel(
            backend: LibraryBackendStub(),
            credentialStore: LibraryCredentialStoreStub()
        )
        let folder = try await model.createLibrary(named: "work", using: account)
        try await model.move(book, to: folder.id, using: account)

        do {
            try await model.deleteLibrary(folder.id, using: account)
            XCTFail("Expected a non-empty library error")
        } catch let error as ReaderBackendError {
            XCTAssertEqual(error.localizedDescription, "move this library's books out first")
        }
        XCTAssertEqual(model.libraryOptions.map(\.title), ["work"])
    }

    func testReorderedBooksSaveRemoteFileOrder() async throws {
        let first = makeBook(title: "First", fingerprint: "first")
        let second = makeBook(title: "Second", fingerprint: "second")
        let firstFileID = UUID()
        let secondFileID = UUID()
        let backend = LibraryBackendStub(
            organization: ReaderLibraryOrganization(
                folders: [],
                files: [
                    makeRemoteFile(id: firstFileID, title: "First", fingerprint: "first"),
                    makeRemoteFile(id: secondFileID, title: "Second", fingerprint: "second")
                ]
            )
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: LibraryCredentialStoreStub(session: makeSession())
        )
        let model = LibraryModel(books: [first, second])
        await model.synchronizeLibraries(using: account)

        model.reorder(second, to: first)
        try await model.persistBookOrder(using: account)

        let order = await backend.lastSavedOrder
        XCTAssertEqual(order, [secondFileID, firstFileID])
    }

    func testRemoteOrderAndFolderMembershipApplyOnInitializationSync() async throws {
        let first = makeBook(title: "First", fingerprint: "first")
        let second = makeBook(title: "Second", fingerprint: "second")
        let folderID = UUID()
        let secondFile = ReaderLibraryFile(
            id: UUID(),
            folderID: folderID,
            displayName: "Second",
            originalFilename: "Second.txt",
            mediaType: "text/plain",
            byteSize: 1,
            sha256: "second",
            status: "ready",
            sortOrder: 0
        )
        let firstFile = makeRemoteFile(
            id: UUID(),
            title: "First",
            fingerprint: "first",
            sortOrder: 1
        )
        let backend = LibraryBackendStub(
            organization: ReaderLibraryOrganization(
                folders: [ReaderLibraryFolder(id: folderID, name: "favorites")],
                files: [firstFile, secondFile]
            )
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: LibraryCredentialStoreStub(session: makeSession())
        )
        let model = LibraryModel(books: [first, second])

        await model.synchronizeLibraries(using: account)

        XCTAssertEqual(model.books.map(\.title), ["Second", "First"])
        XCTAssertEqual(model.libraryOptions.map(\.title), ["favorites"])
        XCTAssertEqual(
            model.books(for: .everything, in: folderID).map(\.title),
            ["Second"]
        )
    }

    func testLibrarySyncRestoresReadyCloudFileIntoEmptyLocalStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReaderCloudRestoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cloudURL = directory.appending(path: "Moby-Dick.txt")
        let contents = Data("Call me Ishmael.".utf8)
        try contents.write(to: cloudURL)
        let fingerprint = try FileFingerprint.sha256(of: cloudURL)
        let fileID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let remoteFile = ReaderLibraryFile(
            id: fileID,
            folderID: nil,
            displayName: "Moby-Dick",
            originalFilename: "Moby-Dick.txt",
            mediaType: "text/plain",
            byteSize: Int64(contents.count),
            sha256: fingerprint,
            status: "ready"
        )
        let backend = LibraryBackendStub(
            organization: ReaderLibraryOrganization(
                folders: [],
                files: [remoteFile]
            ),
            downloadURL: cloudURL
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: LibraryCredentialStoreStub(session: makeSession())
        )
        let store = try ReaderLibraryStore(
            rootURL: directory.appending(path: "LocalLibrary")
        )
        let model = try LibraryModel(store: store)

        await model.synchronizeLibraries(using: account)

        let restored = try XCTUnwrap(model.books.first)
        XCTAssertEqual(restored.id, fileID)
        XCTAssertEqual(restored.title, "Moby-Dick")
        XCTAssertEqual(restored.publication?.fingerprint, fingerprint)
        XCTAssertEqual(try store.loadBooks().map(\.id), [fileID])
        var downloadCount = await backend.downloadCount
        XCTAssertEqual(downloadCount, 1)

        await model.synchronizeLibraries(using: account)

        XCTAssertEqual(model.books.count, 1)
        downloadCount = await backend.downloadCount
        XCTAssertEqual(downloadCount, 1)
    }

    func testFreshLibraryRestoresFoldersFilesMembershipAndRemoteOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReaderFreshLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appending(path: "First.txt")
        let secondURL = directory.appending(path: "Second.txt")
        try Data("first cloud book".utf8).write(to: firstURL)
        try Data("second cloud book".utf8).write(to: secondURL)
        let firstFingerprint = try FileFingerprint.sha256(of: firstURL)
        let secondFingerprint = try FileFingerprint.sha256(of: secondURL)
        let firstID = UUID()
        let secondID = UUID()
        let folderID = UUID()
        let firstFile = ReaderLibraryFile(
            id: firstID,
            folderID: nil,
            displayName: "First",
            originalFilename: "First.txt",
            mediaType: "text/plain",
            byteSize: Int64(try Data(contentsOf: firstURL).count),
            sha256: firstFingerprint,
            status: "ready",
            sortOrder: 1
        )
        let secondFile = ReaderLibraryFile(
            id: secondID,
            folderID: folderID,
            displayName: "Second",
            originalFilename: "Second.txt",
            mediaType: "text/plain",
            byteSize: Int64(try Data(contentsOf: secondURL).count),
            sha256: secondFingerprint,
            status: "ready",
            sortOrder: 0
        )
        let backend = LibraryBackendStub(
            organization: ReaderLibraryOrganization(
                folders: [ReaderLibraryFolder(id: folderID, name: "saved")],
                files: [firstFile, secondFile]
            ),
            downloadURLs: [firstID: firstURL, secondID: secondURL]
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: LibraryCredentialStoreStub(session: makeSession())
        )
        let store = try ReaderLibraryStore(
            rootURL: directory.appending(path: "NewAppLibrary")
        )
        let model = try LibraryModel(store: store)

        await model.synchronizeLibraries(using: account)

        XCTAssertEqual(model.libraryOptions.map(\.title), ["saved"])
        XCTAssertEqual(model.books.map(\.title), ["Second", "First"])
        XCTAssertEqual(
            model.books(for: .everything, in: folderID).map(\.title),
            ["Second"]
        )
        let downloadCount = await backend.downloadCount
        XCTAssertEqual(downloadCount, 2)

        let reopened = try ReaderLibraryStore(
            rootURL: directory.appending(path: "NewAppLibrary")
        )
        XCTAssertEqual(try reopened.loadBooks().map(\.title), ["Second", "First"])
    }

    func testLibrarySyncRejectsCloudFileWithWrongFingerprint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReaderCloudIntegrityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cloudURL = directory.appending(path: "Changed.txt")
        let contents = Data("Changed after upload".utf8)
        try contents.write(to: cloudURL)
        let remoteFile = ReaderLibraryFile(
            id: UUID(),
            folderID: nil,
            displayName: "Changed",
            originalFilename: "Changed.txt",
            mediaType: "text/plain",
            byteSize: Int64(contents.count),
            sha256: String(repeating: "a", count: 64),
            status: "ready"
        )
        let backend = LibraryBackendStub(
            organization: ReaderLibraryOrganization(
                folders: [],
                files: [remoteFile]
            ),
            downloadURL: cloudURL
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: LibraryCredentialStoreStub(session: makeSession())
        )
        let store = try ReaderLibraryStore(
            rootURL: directory.appending(path: "LocalLibrary")
        )
        let model = try LibraryModel(store: store)

        await model.synchronizeLibraries(using: account)

        XCTAssertTrue(model.books.isEmpty)
        XCTAssertTrue(try store.loadBooks().isEmpty)
        XCTAssertTrue(model.importErrorMessage?.contains("fingerprint") == true)
    }

    func testReadingStateSyncRestoresCloudLocatorAfterCloudFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReaderCloudPositionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cloudURL = directory.appending(path: "Founders.txt")
        let contents = Data("A saved cloud reading position.".utf8)
        try contents.write(to: cloudURL)
        let fingerprint = try FileFingerprint.sha256(of: cloudURL)
        let fileID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let remoteFile = ReaderLibraryFile(
            id: fileID,
            folderID: nil,
            displayName: "Founders",
            originalFilename: "Founders.txt",
            mediaType: "text/plain",
            byteSize: Int64(contents.count),
            sha256: fingerprint,
            status: "ready"
        )
        let locator = ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: "text",
            position: 12,
            progression: 0.6
        )
        let backend = LibraryBackendStub(
            organization: ReaderLibraryOrganization(
                folders: [],
                files: [remoteFile]
            ),
            downloadURL: cloudURL,
            readingStates: [
                ReaderCloudReadingState(
                    fileID: fileID,
                    locator: locator,
                    progress: 0.6,
                    lastOpenedAt: Date(timeIntervalSince1970: 100),
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: LibraryCredentialStoreStub(session: makeSession()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let store = try ReaderLibraryStore(
            rootURL: directory.appending(path: "LocalLibrary")
        )
        let model = try LibraryModel(store: store)

        await model.synchronizeLibraries(using: account)
        await model.synchronizeReadingStates(using: account)

        XCTAssertEqual(try XCTUnwrap(model.books.first).progress, 0.6, accuracy: 0.0001)
        XCTAssertEqual(
            try store.loadReadingState(publicationID: fileID)?.locator,
            locator
        )
        let uploadCount = await backend.lastReadingStateUploadCount
        XCTAssertEqual(uploadCount, 0)
    }

    private func makeBook(title: String, fingerprint: String) -> Book {
        Book(
            title: title,
            author: "Author",
            progress: 0,
            coverStyle: .night,
            formatLabel: "EPUB",
            readingLength: .reflowable,
            sample: ReadingSample(chapter: "", section: "", paragraphs: []),
            publication: PublicationReference(
                sourceURL: URL(fileURLWithPath: "/tmp/\(fingerprint).epub"),
                format: .epub,
                fingerprint: fingerprint,
                coverURL: nil
            )
        )
    }

    private func makeRemoteFile(
        id: UUID,
        title: String,
        fingerprint: String,
        sortOrder: Int? = nil
    ) -> ReaderLibraryFile {
        ReaderLibraryFile(
            id: id,
            folderID: nil,
            displayName: title,
            originalFilename: "\(title).txt",
            mediaType: "text/plain",
            byteSize: 1,
            sha256: fingerprint,
            status: "ready",
            sortOrder: sortOrder
        )
    }

    private func makeSession() -> ReaderAuthSession {
        ReaderAuthSession(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: 4_000_000_000,
            user: ReaderAuthUser(id: "user", email: "reader@example.com")
        )
    }
}

private actor LibraryBackendStub: ReaderBackendServicing {
    let organization: ReaderLibraryOrganization
    let downloadURL: URL?
    let downloadURLs: [UUID: URL]
    let readingStates: [ReaderCloudReadingState]
    private(set) var downloadCount = 0
    private(set) var lastReadingStateUploadCount = -1
    private(set) var lastRename: (id: UUID, name: String)?
    private(set) var deletedLibraryID: UUID?
    private(set) var lastSavedOrder: [UUID] = []

    init(
        organization: ReaderLibraryOrganization = .empty,
        downloadURL: URL? = nil,
        downloadURLs: [UUID: URL] = [:],
        readingStates: [ReaderCloudReadingState] = []
    ) {
        self.organization = organization
        self.downloadURL = downloadURL
        self.downloadURLs = downloadURLs
        self.readingStates = readingStates
    }

    func signIn(email: String, password: String) async throws -> ReaderAuthSession {
        throw ReaderBackendError.invalidConfiguration
    }

    func signUp(email: String, password: String) async throws -> ReaderSignUpResult {
        throw ReaderBackendError.invalidConfiguration
    }

    func refreshSession(refreshToken: String) async throws -> ReaderAuthSession {
        throw ReaderBackendError.invalidConfiguration
    }

    func libraryOrganization(
        accessToken: String
    ) async throws -> ReaderLibraryOrganization {
        organization
    }

    func renameLibrary(
        _ libraryID: UUID,
        name: String,
        accessToken: String
    ) async throws -> ReaderLibraryFolder {
        lastRename = (libraryID, name)
        let current = organization.folders.first { $0.id == libraryID }
        return ReaderLibraryFolder(
            id: libraryID,
            parentID: current?.parentID,
            name: name,
            createdAt: current?.createdAt,
            updatedAt: current?.updatedAt
        )
    }

    func deleteLibrary(
        _ libraryID: UUID,
        accessToken: String
    ) async throws {
        deletedLibraryID = libraryID
    }

    func saveLibraryFileOrder(
        _ fileIDs: [UUID],
        accessToken: String
    ) async throws {
        lastSavedOrder = fileIDs
    }

    func downloadLibraryFile(
        _ fileID: UUID,
        accessToken: String
    ) async throws -> URL {
        downloadCount += 1
        guard let downloadURL = downloadURLs[fileID] ?? downloadURL else {
            throw ReaderBackendError.invalidConfiguration
        }
        return downloadURL
    }

    func syncReadingStates(
        _ states: [ReaderCloudReadingState],
        deviceID: UUID,
        accessToken: String
    ) async throws -> [ReaderCloudReadingState] {
        lastReadingStateUploadCount = states.count
        return readingStates
    }

    func answerHighlightQuestion(
        _ request: HighlightQuestionRequest,
        accessToken: String
    ) async throws -> HighlightQuestionAnswer {
        throw ReaderBackendError.invalidConfiguration
    }

    func streamChat(
        _ request: ReaderChatRequest,
        accessToken: String
    ) async throws -> AsyncThrowingStream<ReaderChatStreamEvent, Error> {
        throw ReaderBackendError.invalidConfiguration
    }

    func generateChatTitle(
        _ request: ReaderChatTitleRequest,
        accessToken: String
    ) async throws -> ReaderChatTitle {
        throw ReaderBackendError.invalidConfiguration
    }

    func ingestBookKnowledge(
        _ request: ReaderBookKnowledgeIngestionRequest,
        accessToken: String
    ) async throws {
        throw ReaderBackendError.invalidConfiguration
    }

    func syncLibraryFile(
        _ upload: ReaderLibraryFileUpload,
        accessToken: String
    ) async throws {
        throw ReaderBackendError.invalidConfiguration
    }
}

private final class LibraryCredentialStoreStub: ReaderCredentialStoring, @unchecked Sendable {
    private var session: ReaderAuthSession?

    init(session: ReaderAuthSession? = nil) {
        self.session = session
    }

    func load() throws -> ReaderAuthSession? { session }
    func save(_ session: ReaderAuthSession) throws {}
    func remove() throws {}
}

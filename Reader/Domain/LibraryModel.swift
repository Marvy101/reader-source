import Foundation
import Observation

enum LibraryDestination: String, Hashable {
    case library
    case readingNow
    case highlights
}

enum ReaderCloudBookSyncState: Equatable, Sendable {
    case localOnly
    case syncing
    case synced(Date)
    case failed(String)
}

private enum ReaderCloudSyncOutcome: Sendable {
    case synced(UUID)
    case failed(UUID, String)
}

private enum ReaderLibraryRestoreError: LocalizedError {
    case unsupportedMediaType(String)
    case invalidDownload
    case byteSizeMismatch
    case fingerprintMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedMediaType(let mediaType):
            "Reader cannot restore a cloud file with type \(mediaType)."
        case .invalidDownload:
            "Reader received an invalid cloud file."
        case .byteSizeMismatch:
            "The restored file size did not match the cloud record."
        case .fingerprintMismatch:
            "The restored file did not match its cloud fingerprint."
        }
    }
}

@MainActor
@Observable
final class LibraryModel {
    var books: [Book]
    var destination: LibraryDestination?
    var searchText = ""
    var openBook: Book?
    var showImporter = false
    var importErrorMessage: String?
    private(set) var highlights: [QuietHighlightItem] = []
    private(set) var conversations: [ReaderConversation] = []
    private(set) var libraryFolders: [ReaderLibraryFolder] = []
    private(set) var libraryFiles: [ReaderLibraryFile] = []
    private(set) var isRefreshingLibraries = false
    private(set) var cloudBookSyncStates: [UUID: ReaderCloudBookSyncState] = [:]
    private(set) var isReconcilingCloudLibrary = false
    private(set) var lastCloudSyncAt: Date?
    private(set) var isSyncingReadingStates = false
    private(set) var hasResumeBook: Bool
    var selectedLibraryID: UUID?
    var pendingLocator: ReaderLocator?

    private let store: ReaderLibraryStore?
    private var readerSessions: [UUID: WeakReaderSession] = [:]
    private var usesLibraryPreview = false
    @ObservationIgnored private var knowledgeCache: [UUID: ReaderBookKnowledgeSnapshot] = [:]
    @ObservationIgnored private var resumeSentenceCache: ResumeSentenceCache?
    @ObservationIgnored private var readingStateSyncTask: Task<Void, Never>?
    @ObservationIgnored var onBookKnowledgeAvailable: ((ReaderBookKnowledgeSnapshot) -> Void)?
    @ObservationIgnored var onBookImported: ((Book) -> Void)?
    @ObservationIgnored private var cloudReconciliationRequested = false

    init(
        books: [Book],
        destination: LibraryDestination? = .library,
        store: ReaderLibraryStore? = nil
    ) {
        self.books = books
        self.destination = destination
        self.store = store
        cloudBookSyncStates = Dictionary(
            uniqueKeysWithValues: books.map { ($0.id, .localOnly) }
        )
        if let store {
            do {
                let record = try store.loadMostRecentReadingRecord()
                hasResumeBook = record.map { record in
                    books.contains { $0.id == record.publicationID }
                } ?? false
            } catch {
                hasResumeBook = false
            }
        } else {
            hasResumeBook = false
        }
        reloadCollectedItems()
    }

    convenience init(
        store: ReaderLibraryStore,
        destination: LibraryDestination? = .library
    ) throws {
        try store.reconcileManagedImports()
        try self.init(
            books: store.loadBooks(),
            destination: destination,
            store: store
        )
    }

    static func live() -> LibraryModel {
        do {
            return try LibraryModel(store: ReaderLibraryStore.live())
        } catch {
            let model = LibraryModel(books: [])
            model.importErrorMessage = "Reader could not open its local library. \(error.localizedDescription)"
            return model
        }
    }

    var filteredBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let booksForDestination = destination == .readingNow
            ? books.filter { $0.progress > 0 && $0.progress < 1 }
            : books

        guard !query.isEmpty else { return booksForDestination }

        return booksForDestination.filter { book in
            book.title.localizedCaseInsensitiveContains(query)
                || book.author.localizedCaseInsensitiveContains(query)
        }
    }

    var currentBook: Book? {
        books
            .filter { $0.progress > 0 && $0.progress < 1 }
            .max { $0.progress < $1.progress }
    }

    func books(for filter: QuietLibraryFilter) -> [Book] {
        switch filter {
        case .everything:
            books
        case .reading:
            books.filter { $0.progress > 0 && $0.progress < 0.995 }
        case .papers:
            books.filter { $0.publication?.format == .pdf }
        case .finished:
            books.filter { $0.progress >= 0.995 }
        }
    }

    func books(
        for filter: QuietLibraryFilter,
        in libraryID: UUID?
    ) -> [Book] {
        let filtered = books(for: filter)
        guard let libraryID else { return filtered }
        let fingerprints = Set(
            libraryFiles.compactMap { file in
                file.folderID == libraryID && file.status == "ready"
                    ? file.sha256
                    : nil
            }
        )
        return filtered.filter { book in
            guard let fingerprint = book.publication?.fingerprint else { return false }
            return fingerprints.contains(fingerprint)
        }
    }

    var libraryOptions: [ReaderLibraryOption] {
        libraryFolders.libraryOptions
    }

    var cloudSyncMessage: String {
        let syncableBooks = books.filter { $0.publication != nil }
        guard !syncableBooks.isEmpty else { return "nothing to sync" }

        let states = syncableBooks.map {
            cloudBookSyncStates[$0.id] ?? .localOnly
        }
        let syncedCount = states.filter {
            if case .synced = $0 { return true }
            return false
        }.count
        let failedCount = states.filter {
            if case .failed = $0 { return true }
            return false
        }.count

        if isReconcilingCloudLibrary || states.contains(.syncing) {
            return "syncing \(syncedCount) of \(syncableBooks.count) books"
        }
        if failedCount > 0 {
            let noun = failedCount == 1 ? "book" : "books"
            return "\(syncedCount) of \(syncableBooks.count) synced · \(failedCount) \(noun) will retry"
        }
        if syncedCount == syncableBooks.count, lastCloudSyncAt != nil {
            let noun = syncedCount == 1 ? "book" : "books"
            return "\(syncedCount) \(noun) synced just now"
        }
        if syncedCount > 0 {
            return "\(syncedCount) of \(syncableBooks.count) books synced"
        }
        return "\(syncableBooks.count) books stored on this mac"
    }

    func libraryID(for book: Book) -> UUID? {
        guard let fingerprint = book.publication?.fingerprint else { return nil }
        return libraryFiles.first {
            $0.sha256 == fingerprint && $0.status == "ready"
        }?.folderID
    }

    func reorder(_ book: Book, to target: Book) {
        guard book.id != target.id else { return }
        guard
            let sourceIndex = books.firstIndex(where: { $0.id == book.id }),
            let targetIndex = books.firstIndex(where: { $0.id == target.id })
        else { return }

        let movedBook = books.remove(at: sourceIndex)
        let insertionIndex = min(targetIndex, books.endIndex)
        books.insert(movedBook, at: insertionIndex)
    }

    func persistBookOrder(using account: ReaderAccountModel) async throws {
        try store?.saveBookOrder(books.map(\.id))
        guard !usesLibraryPreview, account.isAuthenticated else { return }

        let fileIDByFingerprint = libraryFiles.reduce(into: [String: UUID]()) {
            result, file in
            if let fingerprint = file.sha256, result[fingerprint] == nil {
                result[fingerprint] = file.id
            }
        }
        let orderedFileIDs = books.compactMap { book in
            book.publication.flatMap { fileIDByFingerprint[$0.fingerprint] }
        }
        try await account.saveLibraryFileOrder(orderedFileIDs)
    }

    func synchronizeLibraries(using account: ReaderAccountModel) async {
        guard !usesLibraryPreview, !isRefreshingLibraries else { return }
        isRefreshingLibraries = true
        defer { isRefreshingLibraries = false }
        do {
            let organization = try await account.libraryOrganization()
            libraryFolders = organization.folders
            libraryFiles = organization.files
            await restoreMissingLibraryFiles(
                organization.files,
                using: account
            )
            applyRemoteBookOrder(organization.files)
            if
                let selectedLibraryID,
                !libraryFolders.contains(where: { $0.id == selectedLibraryID })
            {
                self.selectedLibraryID = nil
            }
        } catch {
            // Library organization is optional UI state. Local reading stays available offline.
        }
    }

    private func applyRemoteBookOrder(_ files: [ReaderLibraryFile]) {
        guard files.contains(where: { $0.sortOrder != nil }) else { return }
        let orderedFingerprints = files
            .filter { $0.status == "ready" }
            .sorted {
                ($0.sortOrder ?? .max, $0.id.uuidString)
                    < ($1.sortOrder ?? .max, $1.id.uuidString)
            }
            .compactMap(\.sha256)
        guard !orderedFingerprints.isEmpty else { return }

        let booksByFingerprint = books.reduce(into: [String: Book]()) {
            result, book in
            if let fingerprint = book.publication?.fingerprint,
               result[fingerprint] == nil {
                result[fingerprint] = book
            }
        }
        let orderedBooks = orderedFingerprints.compactMap { booksByFingerprint[$0] }
        let orderedBookIDs = Set(orderedBooks.map(\.id))
        books = orderedBooks + books.filter { !orderedBookIDs.contains($0.id) }
        try? store?.saveBookOrder(books.map(\.id))
    }

    func reconcileCloudLibrary(using account: ReaderAccountModel) async {
        guard !usesLibraryPreview else { return }
        guard account.isAuthenticated else {
            resetCloudSyncStatus()
            return
        }

        cloudReconciliationRequested = true
        guard !isReconcilingCloudLibrary else { return }
        isReconcilingCloudLibrary = true
        defer { isReconcilingCloudLibrary = false }

        repeat {
            cloudReconciliationRequested = false
            await performCloudReconciliation(using: account)
        } while cloudReconciliationRequested && account.isAuthenticated
    }

    func synchronizeBookWithCloud(
        _ book: Book,
        snapshot preparedSnapshot: ReaderBookKnowledgeSnapshot? = nil,
        using account: ReaderAccountModel
    ) async {
        guard !usesLibraryPreview, account.isAuthenticated else { return }
        cloudBookSyncStates[book.id] = .syncing
        let snapshot = preparedSnapshot ?? bookKnowledge(for: book.id)
        let outcome = await cloudSyncOutcome(
            for: book,
            snapshot: snapshot,
            using: account
        )
        apply(outcome)
        if case .synced = outcome {
            lastCloudSyncAt = .now
        }
        await synchronizeLibraries(using: account)
    }

    func resetCloudSyncStatus() {
        cloudReconciliationRequested = false
        isReconcilingCloudLibrary = false
        lastCloudSyncAt = nil
        cloudBookSyncStates = Dictionary(
            uniqueKeysWithValues: books.map { ($0.id, .localOnly) }
        )
    }

    private func performCloudReconciliation(
        using account: ReaderAccountModel
    ) async {
        await synchronizeLibraries(using: account)
        let syncableBooks = books.filter { $0.publication != nil }
        guard !syncableBooks.isEmpty else {
            lastCloudSyncAt = .now
            return
        }

        for book in syncableBooks {
            cloudBookSyncStates[book.id] = .syncing
        }

        for start in stride(from: 0, to: syncableBooks.count, by: 2) {
            guard account.isAuthenticated else { return }
            let end = min(start + 2, syncableBooks.count)
            let batch = Array(syncableBooks[start..<end])
            let jobs = batch.map { book in
                (book, bookKnowledge(for: book.id))
            }

            await withTaskGroup(of: ReaderCloudSyncOutcome.self) { group in
                for (book, snapshot) in jobs {
                    group.addTask {
                        await self.cloudSyncOutcome(
                            for: book,
                            snapshot: snapshot,
                            using: account,
                            forceRemoteCheck: true
                        )
                    }
                }
                for await outcome in group {
                    apply(outcome)
                }
            }
        }

        let failures = syncableBooks.filter {
            if case .failed = cloudBookSyncStates[$0.id] { return true }
            return false
        }
        if failures.isEmpty { lastCloudSyncAt = .now }
        await synchronizeLibraries(using: account)
    }

    private func cloudSyncOutcome(
        for book: Book,
        snapshot: ReaderBookKnowledgeSnapshot?,
        using account: ReaderAccountModel,
        forceRemoteCheck: Bool = false
    ) async -> ReaderCloudSyncOutcome {
        do {
            try await account.prepareBookForCloud(
                book,
                snapshot: snapshot,
                forceRemoteCheck: forceRemoteCheck
            )
            return .synced(book.id)
        } catch {
            return .failed(book.id, error.localizedDescription)
        }
    }

    private func apply(_ outcome: ReaderCloudSyncOutcome) {
        switch outcome {
        case .synced(let bookID):
            cloudBookSyncStates[bookID] = .synced(.now)
        case .failed(let bookID, let message):
            cloudBookSyncStates[bookID] = .failed(message)
        }
    }

    func synchronizeReadingStates(using account: ReaderAccountModel) async {
        guard
            !usesLibraryPreview,
            !isSyncingReadingStates,
            let store,
            account.isAuthenticated
        else { return }
        isSyncingReadingStates = true
        defer { isSyncingReadingStates = false }

        do {
            let localRecords = try store.loadAllReadingRecords()
            let localStates = localRecords.compactMap { record -> ReaderCloudReadingState? in
                guard
                    let locator = record.state.locator,
                    let lastOpenedAt = record.state.lastOpenedAt,
                    let fileID = cloudFileID(for: record.publicationID)
                else { return nil }
                return ReaderCloudReadingState(
                    fileID: fileID,
                    locator: locator,
                    progress: record.state.progress,
                    lastOpenedAt: lastOpenedAt,
                    updatedAt: record.state.updatedAt
                )
            }
            let remoteStates = try await account.syncReadingStates(localStates)
            let remoteRecords = remoteStates.compactMap { state -> StoredReadingRecord? in
                guard let publicationID = localPublicationID(for: state.fileID) else {
                    return nil
                }
                return StoredReadingRecord(
                    publicationID: publicationID,
                    state: StoredReadingState(
                        locator: state.locator,
                        progress: state.progress,
                        lastOpenedAt: state.lastOpenedAt,
                        updatedAt: state.updatedAt
                    )
                )
            }
            let applied = try store.mergeSyncedReadingRecords(remoteRecords)
            for record in applied {
                updateProgress(record.state.progress, for: record.publicationID)
                readerSessions[record.publicationID]?.session?
                    .applySyncedReadingState(record.state)
            }
        } catch {
            // Reading-state sync is opportunistic. The local checkpoint stays authoritative offline.
        }
    }

    func scheduleReadingStateSynchronization(using account: ReaderAccountModel) {
        readingStateSyncTask?.cancel()
        readingStateSyncTask = Task { [weak self, weak account] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let account else { return }
            self.readingStateSyncTask = nil
            await self.synchronizeReadingStates(using: account)
        }
    }

    private func cloudFileID(for publicationID: UUID) -> UUID? {
        if let exact = libraryFiles.first(where: { $0.id == publicationID }) {
            return exact.id
        }
        guard
            let book = books.first(where: { $0.id == publicationID }),
            let fingerprint = book.publication?.fingerprint
        else { return nil }
        return libraryFiles.first {
            $0.status == "ready" && $0.sha256 == fingerprint
        }?.id ?? publicationID
    }

    private func localPublicationID(for fileID: UUID) -> UUID? {
        if books.contains(where: { $0.id == fileID }) {
            return fileID
        }
        guard
            let fingerprint = libraryFiles.first(where: { $0.id == fileID })?.sha256
        else { return nil }
        return books.first {
            $0.publication?.fingerprint == fingerprint
        }?.id
    }

    private func restoreMissingLibraryFiles(
        _ remoteFiles: [ReaderLibraryFile],
        using account: ReaderAccountModel
    ) async {
        guard let store else { return }
        var localIDs = Set(books.map(\.id))
        var localFingerprints = Set(
            books.compactMap { $0.publication?.fingerprint }
        )
        var restoredAnyBook = false

        for file in remoteFiles where file.status == "ready" {
            guard
                !localIDs.contains(file.id),
                let expectedFingerprint = file.sha256,
                !localFingerprints.contains(expectedFingerprint)
            else {
                continue
            }

            do {
                let downloadedURL = try await account.downloadLibraryFile(file.id)
                defer { try? FileManager.default.removeItem(at: downloadedURL) }
                let restoredBook = try restoreDownloadedBook(
                    file,
                    downloadedURL: downloadedURL,
                    libraryRoot: store.paths.rootURL
                )
                try store.saveImportedBook(restoredBook)
                books.append(restoredBook)
                localIDs.insert(restoredBook.id)
                localFingerprints.insert(expectedFingerprint)
                restoredAnyBook = true
            } catch {
                if importErrorMessage == nil {
                    importErrorMessage = "Reader could not restore \(file.displayName). \(error.localizedDescription)"
                }
            }
        }

        if restoredAnyBook {
            reloadCollectedItems()
        }
    }

    private func restoreDownloadedBook(
        _ file: ReaderLibraryFile,
        downloadedURL: URL,
        libraryRoot: URL
    ) throws -> Book {
        let values = try downloadedURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard
            values.isRegularFile == true,
            let byteSize = values.fileSize,
            byteSize > 0
        else {
            throw ReaderLibraryRestoreError.invalidDownload
        }
        guard Int64(byteSize) == file.byteSize else {
            throw ReaderLibraryRestoreError.byteSizeMismatch
        }
        guard let expectedFingerprint = file.sha256 else {
            throw ReaderLibraryRestoreError.fingerprintMismatch
        }
        let downloadedFingerprint = try FileFingerprint.sha256(of: downloadedURL)
        guard downloadedFingerprint == expectedFingerprint else {
            throw ReaderLibraryRestoreError.fingerprintMismatch
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "ReaderCloudRestore", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let stagedURL = stagingDirectory.appending(
            path: try restoreFilename(for: file)
        )
        try FileManager.default.copyItem(at: downloadedURL, to: stagedURL)
        let imported = try PublicationImportService.importBook(
            from: stagedURL,
            libraryRoot: libraryRoot
        )
        guard imported.publication?.fingerprint == expectedFingerprint else {
            throw ReaderLibraryRestoreError.fingerprintMismatch
        }

        return Book(
            id: file.id,
            title: file.displayName,
            author: imported.author,
            progress: 0,
            coverStyle: imported.coverStyle,
            formatLabel: imported.formatLabel,
            readingLength: imported.readingLength,
            sample: imported.sample,
            publication: imported.publication
        )
    }

    private func restoreFilename(for file: ReaderLibraryFile) throws -> String {
        let fileExtension: String
        switch file.mediaType.lowercased() {
        case "application/pdf":
            fileExtension = "pdf"
        case "application/epub+zip":
            fileExtension = "epub"
        case "text/plain":
            fileExtension = "txt"
        default:
            throw ReaderLibraryRestoreError.unsupportedMediaType(file.mediaType)
        }

        let originalName = URL(fileURLWithPath: file.originalFilename)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = originalName.isEmpty || originalName == "."
            ? file.id.uuidString
            : originalName
        return "\(stem).\(fileExtension)"
    }

    @discardableResult
    func createLibrary(
        named rawName: String,
        using account: ReaderAccountModel
    ) async throws -> ReaderLibraryFolder {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ReaderBackendError.server(
                code: "invalid_library_name",
                message: "give this library a name"
            )
        }
        let folder: ReaderLibraryFolder
        if usesLibraryPreview {
            folder = ReaderLibraryFolder(name: name)
        } else {
            folder = try await account.createLibrary(name: name)
        }
        libraryFolders.removeAll { $0.id == folder.id }
        libraryFolders.append(folder)
        return folder
    }

    @discardableResult
    func renameLibrary(
        _ libraryID: UUID,
        to rawName: String,
        using account: ReaderAccountModel
    ) async throws -> ReaderLibraryFolder {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ReaderBackendError.server(
                code: "invalid_library_name",
                message: "give this library a name"
            )
        }
        guard let index = libraryFolders.firstIndex(where: { $0.id == libraryID }) else {
            throw ReaderBackendError.server(
                code: "folder_not_found",
                message: "library not found"
            )
        }

        let folder: ReaderLibraryFolder
        if usesLibraryPreview {
            let current = libraryFolders[index]
            folder = ReaderLibraryFolder(
                id: current.id,
                parentID: current.parentID,
                name: name,
                createdAt: current.createdAt,
                updatedAt: current.updatedAt
            )
        } else {
            folder = try await account.renameLibrary(libraryID, name: name)
        }
        libraryFolders[index] = folder
        return folder
    }

    func deleteLibrary(
        _ libraryID: UUID,
        using account: ReaderAccountModel
    ) async throws {
        guard !libraryFiles.contains(where: { $0.folderID == libraryID }) else {
            throw ReaderBackendError.server(
                code: "folder_not_empty",
                message: "move this library's books out first"
            )
        }
        if !usesLibraryPreview {
            try await account.deleteLibrary(libraryID)
        }
        libraryFolders.removeAll { $0.id == libraryID }
        if selectedLibraryID == libraryID {
            selectedLibraryID = nil
        }
    }

    func move(
        _ book: Book,
        to libraryID: UUID?,
        using account: ReaderAccountModel
    ) async throws {
        guard
            let fingerprint = book.publication?.fingerprint,
            let index = libraryFiles.firstIndex(where: {
                $0.sha256 == fingerprint && $0.status == "ready"
            })
        else {
            throw ReaderBackendError.server(
                code: "book_not_synced",
                message: "this book is still syncing"
            )
        }
        let updated: ReaderLibraryFile
        if usesLibraryPreview {
            var previewFile = libraryFiles[index]
            previewFile.folderID = libraryID
            updated = previewFile
        } else {
            updated = try await account.moveLibraryFile(
                libraryFiles[index].id,
                to: libraryID
            )
        }
        libraryFiles[index] = updated
    }

    func installLibraryPreview() {
        usesLibraryPreview = true
        libraryFolders = []
        libraryFiles = books.compactMap { book in
            guard let publication = book.publication else { return nil }
            return ReaderLibraryFile(
                id: UUID(),
                folderID: nil,
                displayName: book.title,
                originalFilename: publication.sourceURL.lastPathComponent,
                mediaType: publication.format.rawValue,
                byteSize: 1,
                sha256: publication.fingerprint,
                status: "ready"
            )
        }
    }

    func resumeSnapshot() -> QuietResumeSnapshot? {
        guard
            let record = try? store?.loadMostRecentReadingRecord(),
            let book = books.first(where: { $0.id == record.publicationID }),
            let openedAt = record.state.lastOpenedAt
        else { return nil }

        let fallback = "You stopped on page \(max(Int(book.progress * Double(book.totalPageCount ?? 1)), 1))."
        let sentence: String
        if let cached = resumeSentenceCache, cached.record == record {
            sentence = cached.sentence
        } else if let locator = record.state.locator {
            sentence = resumeSentence(for: book, at: locator) ?? fallback
            resumeSentenceCache = ResumeSentenceCache(
                record: record,
                sentence: sentence
            )
        } else {
            sentence = fallback
            resumeSentenceCache = ResumeSentenceCache(
                record: record,
                sentence: sentence
            )
        }
        return QuietResumeSnapshot(
            book: book,
            sentence: sentence,
            openedAt: openedAt
        )
    }

    private func resumeSentence(
        for book: Book,
        at locator: ReaderLocator
    ) -> String? {
        guard let reference = book.publication else {
            return locator.textAnchor?.exact
        }

        let chunk: PublicationTextChunk?
        switch reference.format {
        case .pdf:
            chunk = try? PDFKitReadingAdapter.resumeTextChunk(
                reference: reference,
                locator: locator
            )
        case .epub, .plainText:
            chunk = try? WebKitReadingAdapter.resumeTextChunk(
                reference: reference,
                locator: locator
            )
        }

        guard let chunk else { return locator.textAnchor?.exact }
        return ReaderTextIndex(
            publicationFingerprint: reference.fingerprint,
            chunks: [chunk]
        ).sentence(at: locator)
    }

    func open(_ book: Book) {
        openBook = book
    }

    func open(_ book: Book, at locator: ReaderLocator) {
        pendingLocator = locator
        open(book)
    }

    func closeReader() {
        openBook = nil
        pendingLocator = nil
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> [Book] {
        do {
            var importedBooks: [Book] = []
            for url in urls {
                let book = try PublicationImportService.importBook(
                    from: url,
                    libraryRoot: store?.paths.rootURL
                )
                if
                    let fingerprint = book.publication?.fingerprint,
                    books.contains(where: {
                        $0.publication?.fingerprint == fingerprint
                    })
                {
                    continue
                }
                try store?.saveImportedBook(book)
                books.append(book)
                cloudBookSyncStates[book.id] = .localOnly
                importedBooks.append(book)
                onBookImported?(book)
            }

            if let first = importedBooks.first {
                open(first)
            }
            reloadCollectedItems()
            return importedBooks
        } catch {
            importErrorMessage = error.localizedDescription
            return []
        }
    }

    func makeReaderSession(
        for book: Book,
        annotationChanged: ((ReaderAnnotation) -> Void)? = nil,
        readingStateChanged: (() -> Void)? = nil
    ) throws -> PublicationReaderSession {
        let session = try PublicationReaderSession(book: book, store: store)
        let knowledge = session.bookKnowledgeSnapshot()
        knowledgeCache[book.id] = knowledge
        if let knowledge {
            onBookKnowledgeAvailable?(knowledge)
        }
        session.onProgressChanged = { [weak self] progress in
            self?.updateProgress(progress, for: book.id)
        }
        session.onReadingStateChanged = readingStateChanged
        session.onAnnotationsChanged = { [weak self, weak session] annotation in
            guard let self else { return }
            let knowledge = session?.bookKnowledgeSnapshot()
            knowledgeCache[book.id] = knowledge
            if let knowledge {
                onBookKnowledgeAvailable?(knowledge)
            }
            reloadCollectedItems()
            annotationChanged?(annotation)
        }
        readerSessions[book.id] = WeakReaderSession(session)
        if let pendingLocator {
            session.navigate(to: pendingLocator)
            self.pendingLocator = nil
        }
        return session
    }

    func synchronizeAnnotations(using account: ReaderAccountModel) async {
        guard let store else { return }
        do {
            let local = try store.loadAllAnnotations()
            let remote = try await account.syncAnnotations(local)
            try store.mergeSyncedAnnotations(remote)
            reloadCollectedItems()
            readerSessions = readerSessions.filter { _, reference in
                guard let session = reference.session else { return false }
                session.reloadAnnotations()
                return true
            }
        } catch {
            // Sync is opportunistic. Local reading and annotation writes stay authoritative.
        }
    }

    func bookKnowledge(for bookID: UUID) -> ReaderBookKnowledgeSnapshot? {
        guard let book = books.first(where: { $0.id == bookID }) else { return nil }
        let snapshot: ReaderBookKnowledgeSnapshot?
        if let cached = knowledgeCache[bookID] {
            snapshot = cached
        } else {
            let session = try? PublicationReaderSession(book: book, store: store)
            snapshot = session?.bookKnowledgeSnapshot()
            knowledgeCache[bookID] = snapshot
        }
        guard let snapshot else { return nil }
        return ReaderBookKnowledgeSnapshot(
            publicationID: snapshot.publicationID,
            title: snapshot.title,
            author: snapshot.author,
            format: snapshot.format,
            fingerprint: snapshot.fingerprint,
            currentProgression: book.progress,
            currentPageNumber: book.totalPageCount.map { total in
                min(max(Int(book.progress * Double(total)) + 1, 1), total)
            },
            chunks: snapshot.chunks,
            annotations: snapshot.annotations
        )
    }

    func recordConversation(_ conversation: ReaderConversation) {
        do {
            try store?.saveConversation(conversation)
            conversations.removeAll { $0.id == conversation.id }
            conversations.insert(conversation, at: 0)
        } catch {
            importErrorMessage = "Reader could not save that conversation."
        }
    }

    func searchAll(_ rawQuery: String, limit: Int = 80) -> [QuietSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var found: [QuietSearchResult] = []

        for book in books where found.count < limit {
            guard let session = try? PublicationReaderSession(book: book, store: store) else {
                continue
            }
            for result in session.textIndex.search(query, limit: min(20, limit - found.count)) {
                found.append(
                    QuietSearchResult(
                        id: result.id,
                        text: result.excerpt,
                        sourceLine: [book.title, result.resourceTitle]
                            .compactMap { $0 }
                            .joined(separator: " · "),
                        coverStyle: book.coverStyle,
                        source: .publication(bookID: book.id, locator: result.locator)
                    )
                )
            }
        }

        for item in highlights where found.count < limit {
            let noteMatches = item.annotation.note?
                .localizedCaseInsensitiveContains(query) == true
            guard item.annotation.selectedText.localizedCaseInsensitiveContains(query)
                || noteMatches else {
                continue
            }
            found.append(
                QuietSearchResult(
                    id: item.id,
                    text: noteMatches
                        ? item.annotation.note ?? item.annotation.selectedText
                        : item.annotation.selectedText,
                    sourceLine: "\(item.book.title) · \(noteMatches ? "note" : "kept")",
                    coverStyle: item.book.coverStyle,
                    source: .highlight(
                        bookID: item.book.id,
                        locator: item.annotation.locator
                    )
                )
            )
        }

        for conversation in conversations where found.count < limit {
            let searchable = conversation.question + " " + conversation.answer
            guard searchable.localizedCaseInsensitiveContains(query) else { continue }
            found.append(
                QuietSearchResult(
                    id: conversation.id,
                    text: conversation.answer,
                    sourceLine: "ai · \(conversation.publicationTitle)",
                    coverStyle: conversation.publicationID.flatMap { id in
                        books.first(where: { $0.id == id })?.coverStyle
                    },
                    source: .conversation(conversation.id)
                )
            )
        }
        return found
    }

    func reloadCollectedItems() {
        guard let store else {
            highlights = []
            conversations = []
            return
        }
        highlights = books.flatMap { book in
            ((try? store.loadAnnotations(publicationID: book.id)) ?? []).map {
                QuietHighlightItem(annotation: $0, book: book)
            }
        }
        .sorted { $0.annotation.createdAt > $1.annotation.createdAt }
        conversations = (try? store.loadConversations()) ?? []
    }

    private func updateProgress(_ progress: Double, for bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else {
            return
        }
        books[index].progress = min(max(progress, 0), 1)
        if openBook?.id == bookID {
            openBook = books[index]
        }
        hasResumeBook = true
        resumeSentenceCache = nil
    }
}

private struct ResumeSentenceCache {
    let record: StoredReadingRecord
    let sentence: String
}

private final class WeakReaderSession {
    weak var session: PublicationReaderSession?

    init(_ session: PublicationReaderSession) {
        self.session = session
    }
}

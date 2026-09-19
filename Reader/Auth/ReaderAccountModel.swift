import Foundation
import CryptoKit
import Observation

@MainActor
@Observable
final class ReaderAccountModel {
    private(set) var session: ReaderAuthSession?
    private(set) var isAuthenticating = false
    var errorMessage: String?
    var noticeMessage: String?
    private(set) var displayName: String

    private let backend: any ReaderBackendServicing
    private let credentialStore: any ReaderCredentialStoring
    private let defaults: UserDefaults
    private let deviceID: UUID
    private let onlineRequestDisabledMessage: String?
    private var pendingName: String?
    private var preparedBookKeys: Set<String> = []
    private var bookPreparationTasks: [String: Task<Void, Error>] = [:]
    private var syncedFileKeys: Set<String> = []
    private var fileSyncTasks: [String: Task<Void, Error>] = [:]

    init(
        backend: any ReaderBackendServicing,
        credentialStore: any ReaderCredentialStoring,
        defaults: UserDefaults = .standard,
        onlineRequestDisabledMessage: String? = nil
    ) {
        self.backend = backend
        self.credentialStore = credentialStore
        self.defaults = defaults
        let deviceIDKey = "reader-cloud-device-id"
        if
            let storedDeviceID = defaults.string(forKey: deviceIDKey),
            let deviceID = UUID(uuidString: storedDeviceID)
        {
            self.deviceID = deviceID
        } else {
            let deviceID = UUID()
            self.deviceID = deviceID
            defaults.set(deviceID.uuidString, forKey: deviceIDKey)
        }
        self.onlineRequestDisabledMessage = onlineRequestDisabledMessage
        let loadedSession = try? credentialStore.load()
        session = loadedSession
        let identity = loadedSession?.user.id ?? loadedSession?.user.email ?? "reader"
        displayName = defaults.string(forKey: "reader-profile-name-\(identity)")
            ?? loadedSession?.user.email?.split(separator: "@").first.map(String.init)
            ?? "reader"
    }

    static func live() -> ReaderAccountModel {
        ReaderAccountModel(
            backend: ReaderBackendClient.live(),
            credentialStore: KeychainReaderCredentialStore()
        )
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var email: String? {
        session?.user.email
    }

    var accountMark: QuietAccountMark {
        QuietAccountMark.deterministic(
            for: session?.user.id ?? email ?? displayName
        )
    }

    func signIn(email: String, password: String) async {
        await authenticate {
            try await backend.signIn(email: email, password: password)
        }
    }

    func signUp(name: String, email: String, password: String) async {
        pendingName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        await signUp(email: email, password: password)
    }

    func signUp(email: String, password: String) async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        noticeMessage = nil

        do {
            let result = try await backend.signUp(email: email, password: password)
            if let session = result.session {
                try setSession(session)
            } else if result.requiresEmailConfirmation {
                noticeMessage = "Check your email to confirm the account, then sign in."
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isAuthenticating = false
    }

    func signOut() {
        session = nil
        preparedBookKeys = []
        bookPreparationTasks.values.forEach { $0.cancel() }
        bookPreparationTasks = [:]
        syncedFileKeys = []
        fileSyncTasks.values.forEach { $0.cancel() }
        fileSyncTasks = [:]
        try? credentialStore.remove()
        clearFeedback()
    }

    func clearFeedback() {
        errorMessage = nil
        noticeMessage = nil
    }

    func streamChat(
        _ request: ReaderChatRequest
    ) async throws -> AsyncThrowingStream<ReaderChatStreamEvent, Error> {
        let accessToken = try await validAccessToken()
        do {
            return try await backend.streamChat(
                request,
                accessToken: accessToken
            )
        } catch let error as ReaderBackendError where error.isUnauthorized {
            let refreshed = try await refresh()
            return try await backend.streamChat(
                request,
                accessToken: refreshed.accessToken
            )
        }
    }

    func prepareBookKnowledge(
        _ snapshot: ReaderBookKnowledgeSnapshot,
        forceRemoteCheck: Bool = false
    ) async throws {
        let preparationKey = Self.bookPreparationKey(for: snapshot)
        guard forceRemoteCheck || !preparedBookKeys.contains(preparationKey) else {
            return
        }
        if let existing = bookPreparationTasks[preparationKey] {
            return try await existing.value
        }

        let request = ReaderBookKnowledgeIngestionRequest(snapshot: snapshot)
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.ingestBookKnowledge(request)
        }
        bookPreparationTasks[preparationKey] = task
        defer { bookPreparationTasks[preparationKey] = nil }
        try await task.value
        preparedBookKeys.insert(preparationKey)
    }

    func syncOriginalFile(
        for book: Book,
        forceRemoteCheck: Bool = false
    ) async throws {
        guard let publication = book.publication else { return }
        let fileSyncKey = "\(book.id.uuidString):\(publication.fingerprint)"
        guard forceRemoteCheck || !syncedFileKeys.contains(fileSyncKey) else { return }
        if let existing = fileSyncTasks[fileSyncKey] {
            return try await existing.value
        }

        let values = try publication.sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard
            values.isRegularFile == true,
            let byteSize = values.fileSize,
            byteSize > 0
        else {
            throw ReaderBackendError.invalidResponse
        }
        let mediaType: String
        switch publication.format {
        case .pdf:
            mediaType = "application/pdf"
        case .epub:
            mediaType = "application/epub+zip"
        case .plainText:
            mediaType = "text/plain"
        }
        let upload = ReaderLibraryFileUpload(
            publicationID: book.id,
            displayName: book.title,
            sourceURL: publication.sourceURL,
            mediaType: mediaType,
            byteSize: byteSize,
            sha256: publication.fingerprint
        )
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.syncLibraryFile(upload)
        }
        fileSyncTasks[fileSyncKey] = task
        defer { fileSyncTasks[fileSyncKey] = nil }
        try await task.value
        syncedFileKeys.insert(fileSyncKey)
    }

    func prepareBookForCloud(
        _ book: Book,
        snapshot: ReaderBookKnowledgeSnapshot?,
        forceRemoteCheck: Bool = false
    ) async throws {
        async let originalFile: Void = syncOriginalFile(
            for: book,
            forceRemoteCheck: forceRemoteCheck
        )

        guard let snapshot else {
            try await originalFile
            throw ReaderBackendError.server(
                code: "book_text_unavailable",
                message: "Reader could not prepare searchable text for this book."
            )
        }

        async let searchIndex: Void = prepareBookKnowledge(
            snapshot,
            forceRemoteCheck: forceRemoteCheck
        )
        _ = try await (originalFile, searchIndex)
    }

    func searchCatalog(
        _ query: String,
        locale: String = "en-US",
        limit: Int = 20
    ) async throws -> [ReaderCatalogResult] {
        let accessToken = try await validAccessToken()
        do {
            return try await backend.searchCatalog(
                query: query,
                locale: locale,
                limit: limit,
                accessToken: accessToken
            )
        } catch let error as ReaderBackendError where error.isUnauthorized {
            let refreshed = try await refresh()
            return try await backend.searchCatalog(
                query: query,
                locale: locale,
                limit: limit,
                accessToken: refreshed.accessToken
            )
        }
    }

    func registerCatalogInterest(
        _ result: ReaderCatalogResult,
        emailOptIn: Bool = false
    ) async throws {
        let accessToken = try await validAccessToken()
        do {
            try await backend.registerCatalogInterest(
                result,
                emailOptIn: emailOptIn,
                accessToken: accessToken
            )
        } catch let error as ReaderBackendError where error.isUnauthorized {
            let refreshed = try await refresh()
            try await backend.registerCatalogInterest(
                result,
                emailOptIn: emailOptIn,
                accessToken: refreshed.accessToken
            )
        }
    }

    func matchLibraryFile(
        _ publicationID: UUID,
        to result: ReaderCatalogResult,
        source: ReaderCatalogMatchSource
    ) async throws {
        let accessToken = try await validAccessToken()
        do {
            try await backend.matchLibraryFile(
                publicationID,
                to: result,
                source: source,
                accessToken: accessToken
            )
        } catch let error as ReaderBackendError where error.isUnauthorized {
            let refreshed = try await refresh()
            try await backend.matchLibraryFile(
                publicationID,
                to: result,
                source: source,
                accessToken: refreshed.accessToken
            )
        }
    }

    private func syncLibraryFile(_ upload: ReaderLibraryFileUpload) async throws {
        let accessToken = try await validAccessToken()
        do {
            try await backend.syncLibraryFile(upload, accessToken: accessToken)
        } catch let error as ReaderBackendError where error.isUnauthorized {
            let refreshed = try await refresh()
            try await backend.syncLibraryFile(
                upload,
                accessToken: refreshed.accessToken
            )
        }
    }

    private func ingestBookKnowledge(
        _ request: ReaderBookKnowledgeIngestionRequest
    ) async throws {
        let accessToken = try await validAccessToken()
        do {
            try await backend.ingestBookKnowledge(
                request,
                accessToken: accessToken
            )
        } catch let error as ReaderBackendError where error.isUnauthorized {
            let refreshed = try await refresh()
            try await backend.ingestBookKnowledge(
                request,
                accessToken: refreshed.accessToken
            )
        }
    }

    func syncAnnotations(
        _ annotations: [ReaderAnnotation]
    ) async throws -> [ReaderAnnotation] {
        var accessToken = try await validAccessToken()
        let batches = annotations.isEmpty
            ? [[]]
            : stride(from: 0, to: annotations.count, by: 500).map {
                Array(annotations[$0..<min($0 + 500, annotations.count)])
            }
        var remote: [ReaderAnnotation] = []

        for batch in batches {
            do {
                remote = try await backend.syncAnnotations(
                    batch,
                    accessToken: accessToken
                )
            } catch let error as ReaderBackendError where error.isUnauthorized {
                accessToken = try await refresh().accessToken
                remote = try await backend.syncAnnotations(
                    batch,
                    accessToken: accessToken
                )
            }
        }
        return remote
    }

    private static func bookPreparationKey(
        for snapshot: ReaderBookKnowledgeSnapshot
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let annotations = (try? encoder.encode(snapshot.annotations)) ?? Data()
        let annotationFingerprint = SHA256.hash(data: annotations)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(snapshot.publicationID.uuidString):\(snapshot.fingerprint):\(annotationFingerprint)"
    }

    func answerHighlightQuestion(
        _ request: HighlightQuestionRequest
    ) async throws -> HighlightQuestionAnswer {
        try await authenticatedRequest { accessToken in
            try await backend.answerHighlightQuestion(
                request,
                accessToken: accessToken
            )
        }
    }

    func libraryOrganization() async throws -> ReaderLibraryOrganization {
        try await authenticatedRequest { accessToken in
            try await backend.libraryOrganization(accessToken: accessToken)
        }
    }

    func syncReadingStates(
        _ states: [ReaderCloudReadingState]
    ) async throws -> [ReaderCloudReadingState] {
        let batches = states.isEmpty
            ? [[]]
            : stride(from: 0, to: states.count, by: 500).map {
                Array(states[$0..<min($0 + 500, states.count)])
            }
        var remote: [ReaderCloudReadingState] = []
        for batch in batches {
            remote = try await authenticatedRequest { accessToken in
                try await backend.syncReadingStates(
                    batch,
                    deviceID: deviceID,
                    accessToken: accessToken
                )
            }
        }
        return remote
    }

    func createLibrary(name: String) async throws -> ReaderLibraryFolder {
        try await authenticatedRequest { accessToken in
            try await backend.createLibrary(
                name: name,
                parentID: nil,
                accessToken: accessToken
            )
        }
    }

    func renameLibrary(
        _ libraryID: UUID,
        name: String
    ) async throws -> ReaderLibraryFolder {
        try await authenticatedRequest { accessToken in
            try await backend.renameLibrary(
                libraryID,
                name: name,
                accessToken: accessToken
            )
        }
    }

    func deleteLibrary(_ libraryID: UUID) async throws {
        try await authenticatedRequest { accessToken in
            try await backend.deleteLibrary(
                libraryID,
                accessToken: accessToken
            )
        }
    }

    func moveLibraryFile(
        _ fileID: UUID,
        to folderID: UUID?
    ) async throws -> ReaderLibraryFile {
        try await authenticatedRequest { accessToken in
            try await backend.moveLibraryFile(
                fileID,
                to: folderID,
                accessToken: accessToken
            )
        }
    }

    func saveLibraryFileOrder(_ fileIDs: [UUID]) async throws {
        try await authenticatedRequest { accessToken in
            try await backend.saveLibraryFileOrder(
                fileIDs,
                accessToken: accessToken
            )
        }
    }

    func downloadLibraryFile(_ fileID: UUID) async throws -> URL {
        try await authenticatedRequest { accessToken in
            try await backend.downloadLibraryFile(
                fileID,
                accessToken: accessToken
            )
        }
    }

    private func authenticatedRequest<Value: Sendable>(
        _ request: (String) async throws -> Value
    ) async throws -> Value {
        let accessToken = try await validAccessToken()
        do {
            return try await request(accessToken)
        } catch let error as ReaderBackendError where error.isUnauthorized {
            return try await request(try await refresh().accessToken)
        }
    }

    func generateChatTitle(
        firstMessage: String
    ) async throws -> ReaderChatTitle {
        let request = ReaderChatTitleRequest(firstMessage: firstMessage)
        let accessToken = try await validAccessToken()
        do {
            return try await backend.generateChatTitle(
                request,
                accessToken: accessToken
            )
        } catch let error as ReaderBackendError where error.isUnauthorized {
            let refreshed = try await refresh()
            return try await backend.generateChatTitle(
                request,
                accessToken: refreshed.accessToken
            )
        }
    }
    private func authenticate(
        operation: () async throws -> ReaderAuthSession
    ) async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        noticeMessage = nil

        do {
            try setSession(try await operation())
        } catch {
            errorMessage = error.localizedDescription
        }

        isAuthenticating = false
    }

    private func validAccessToken() async throws -> String {
        if let onlineRequestDisabledMessage {
            throw ReaderBackendError.server(
                code: "preview_session",
                message: onlineRequestDisabledMessage
            )
        }
        guard let session else {
            throw ReaderBackendError.server(
                code: "unauthorized",
                message: "Sign in to continue the conversation."
            )
        }
        if let expiresAt = session.expiresAt,
           expiresAt <= Date.now.timeIntervalSince1970 + 60 {
            return try await refresh().accessToken
        }
        return session.accessToken
    }

    private func refresh() async throws -> ReaderAuthSession {
        guard let refreshToken = session?.refreshToken else {
            throw ReaderBackendError.server(
                code: "unauthorized",
                message: "Sign in to continue."
            )
        }
        do {
            let refreshed = try await backend.refreshSession(
                refreshToken: refreshToken
            )
            try setSession(refreshed)
            return refreshed
        } catch {
            signOut()
            throw error
        }
    }

    private func setSession(_ session: ReaderAuthSession) throws {
        try credentialStore.save(session)
        self.session = session
        let identity = session.user.id
        if let pendingName, !pendingName.isEmpty {
            displayName = pendingName
            defaults.set(pendingName, forKey: "reader-profile-name-\(identity)")
            if let email = session.user.email {
                defaults.set(pendingName, forKey: "reader-profile-name-\(email)")
            }
            self.pendingName = nil
        } else if let saved = defaults.string(forKey: "reader-profile-name-\(identity)") {
            displayName = saved
        } else if let email = session.user.email {
            displayName = defaults.string(forKey: "reader-profile-name-\(email)")
                ?? email.split(separator: "@").first.map(String.init)
                ?? "reader"
        }
    }
}

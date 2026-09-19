import XCTest
@testable import Reader

@MainActor
final class ReaderAccountModelTests: XCTestCase {
    func testStoredSessionStartsAuthenticated() throws {
        let session = makeSession(accessToken: "stored")
        let backend = BackendStub(signInSession: session)
        let store = CredentialStoreStub(session: session)

        let account = ReaderAccountModel(backend: backend, credentialStore: store)

        XCTAssertTrue(account.isAuthenticated)
        XCTAssertEqual(account.email, "reader@example.com")
    }

    func testSignInPersistsSession() async throws {
        let session = makeSession(accessToken: "access")
        let backend = BackendStub(signInSession: session)
        let store = CredentialStoreStub()
        let account = ReaderAccountModel(backend: backend, credentialStore: store)

        await account.signIn(email: "reader@example.com", password: "password")

        XCTAssertEqual(account.session, session)
        XCTAssertEqual(try store.load(), session)
    }

    func testSignOutRemovesStoredSession() throws {
        let session = makeSession(accessToken: "stored")
        let backend = BackendStub(signInSession: session)
        let store = CredentialStoreStub(session: session)
        let account = ReaderAccountModel(backend: backend, credentialStore: store)

        account.signOut()

        XCTAssertFalse(account.isAuthenticated)
        XCTAssertNil(try store.load())
    }

    func testCreateAccountPersistsLocalDisplayName() async throws {
        let session = makeSession(accessToken: "access")
        let suite = "ReaderAccountModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = ReaderAccountModel(
            backend: BackendStub(signInSession: session),
            credentialStore: CredentialStoreStub(),
            defaults: defaults
        )

        await account.signUp(
            name: "Ishmael",
            email: "reader@example.com",
            password: "password"
        )

        XCTAssertEqual(account.displayName, "Ishmael")
        XCTAssertEqual(
            defaults.string(forKey: "reader-profile-name-user"),
            "Ishmael"
        )
    }

    func testExpiredSessionRefreshesBeforeStreamingChat() async throws {
        let expired = makeSession(accessToken: "expired", expiresAt: 1)
        let refreshed = makeSession(accessToken: "fresh", expiresAt: 4_000_000_000)
        let backend = BackendStub(
            signInSession: expired,
            refreshedSession: refreshed,
            streamEvents: [
                .delta("Grounded answer"),
                .complete(model: "test", finishReason: "stop")
            ]
        )
        let store = CredentialStoreStub(session: expired)
        let account = ReaderAccountModel(backend: backend, credentialStore: store)

        let stream = try await account.streamChat(makeRequest())
        var events: [ReaderChatStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        let lastAnswerToken = await backend.lastAnswerToken

        XCTAssertEqual(events.first, .delta("Grounded answer"))
        XCTAssertEqual(account.session, refreshed)
        XCTAssertEqual(lastAnswerToken, "fresh")
    }

    func testAnnotationSyncUsesBoundedBatchesAndReturnsCanonicalRemoteSet() async throws {
        let session = makeSession(accessToken: "access")
        let annotation = ReaderAnnotation(
            publicationFingerprint: String(repeating: "a", count: 64),
            locator: ReaderLocator(
                publicationFingerprint: String(repeating: "a", count: 64),
                resourceID: "text",
                position: 0,
                progression: 0
            ),
            selectedText: "Selected"
        )
        let backend = BackendStub(
            signInSession: session,
            syncedAnnotations: [annotation]
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: CredentialStoreStub(session: session)
        )

        let remote = try await account.syncAnnotations(
            Array(repeating: annotation, count: 501)
        )
        let batchSizes = await backend.annotationBatchSizes

        XCTAssertEqual(batchSizes, [500, 1])
        XCTAssertEqual(remote, [annotation])
    }

    func testVisualPreviewNeverSendsItsPlaceholderToken() async throws {
        let session = makeSession(accessToken: "local-preview")
        let backend = BackendStub(signInSession: session)
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: CredentialStoreStub(session: session),
            onlineRequestDisabledMessage: "Open a signed-in build to chat."
        )

        do {
            _ = try await account.streamChat(makeRequest())
            XCTFail("Expected the visual preview to reject online AI requests")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Open a signed-in build to chat.")
        }
        let lastAnswerToken = await backend.lastAnswerToken
        XCTAssertNil(lastAnswerToken)
    }

    func testTLSFailureGetsAReadableError() {
        let error = ReaderBackendClient.normalizedTransportError(
            URLError(.secureConnectionFailed)
        )

        XCTAssertEqual(error, .secureConnectionFailed)
        XCTAssertEqual(
            error.localizedDescription,
            "Reader couldn't establish a secure connection to its AI service. Check your connection and try again."
        )
    }

    func testMissingChatRouteGetsAnEndpointError() {
        let error = ReaderBackendClient.error(forHTTPStatus: 404)

        XCTAssertEqual(error, .endpointUnavailable)
        XCTAssertEqual(
            error.localizedDescription,
            "Reader's AI service needs to be updated. Try again in a moment."
        )
    }

    func testBookPreparationDeduplicatesConcurrentWorkAndRefreshesEditedNotes() async throws {
        let session = makeSession(accessToken: "access")
        let backend = BackendStub(signInSession: session, ingestionDelay: .milliseconds(25))
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: CredentialStoreStub(session: session)
        )
        let annotationID = UUID()
        let original = makeKnowledgeSnapshot(annotationID: annotationID, note: "first note")

        async let first: Void = account.prepareBookKnowledge(original)
        async let duplicate: Void = account.prepareBookKnowledge(original)
        _ = try await (first, duplicate)
        let initialIngestionCount = await backend.ingestionCount
        XCTAssertEqual(initialIngestionCount, 1)

        let edited = makeKnowledgeSnapshot(annotationID: annotationID, note: "edited note")
        try await account.prepareBookKnowledge(edited)
        let refreshedIngestionCount = await backend.ingestionCount
        XCTAssertEqual(refreshedIngestionCount, 2)
    }

    func testOriginalFileSyncDeduplicatesConcurrentWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReaderFileSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "book.txt")
        try "Call me Ishmael.".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let session = makeSession(accessToken: "access")
        let backend = BackendStub(
            signInSession: session,
            fileSyncDelay: .milliseconds(25)
        )
        let account = ReaderAccountModel(
            backend: backend,
            credentialStore: CredentialStoreStub(session: session)
        )
        let book = Book(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            title: "Moby-Dick",
            author: "Herman Melville",
            progress: 0,
            coverStyle: .sea,
            formatLabel: "TXT",
            readingLength: .reflowable,
            sample: ReadingSample(chapter: "", section: "", paragraphs: []),
            publication: PublicationReference(
                sourceURL: sourceURL,
                format: .plainText,
                fingerprint: String(repeating: "a", count: 64),
                coverURL: nil
            )
        )

        async let first: Void = account.syncOriginalFile(for: book)
        async let duplicate: Void = account.syncOriginalFile(for: book)
        _ = try await (first, duplicate)

        let uploads = await backend.fileSyncs
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?.publicationID, book.id)
        XCTAssertEqual(uploads.first?.mediaType, "text/plain")
        XCTAssertEqual(uploads.first?.byteSize, 16)
    }

    private func makeSession(
        accessToken: String,
        expiresAt: Double = 4_000_000_000
    ) -> ReaderAuthSession {
        ReaderAuthSession(
            accessToken: accessToken,
            refreshToken: "refresh",
            expiresAt: expiresAt,
            user: ReaderAuthUser(id: "user", email: "reader@example.com")
        )
    }

    private func makeRequest() -> ReaderChatRequest {
        ReaderChatRequest(
            messages: [
                ReaderAssistantMessage(
                    role: .reader,
                    text: "What does this mean?"
                )
            ],
            source: HighlightQuestionDraft(
                publicationTitle: "Book",
                publicationAuthor: "Author",
                publicationFormat: .plainText,
                selection: ReaderSelection(
                    locator: ReaderLocator(
                        publicationFingerprint: "fingerprint",
                        resourceID: "text",
                        position: 0,
                        progression: 0
                    ),
                    selectedText: "Selected"
                ),
                context: ReaderSelectionContext(before: "", after: "")
            )
        )
    }

    private func makeKnowledgeSnapshot(
        annotationID: UUID,
        note: String
    ) -> ReaderBookKnowledgeSnapshot {
        ReaderBookKnowledgeSnapshot(
            publicationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            title: "Book",
            author: "Author",
            format: .plainText,
            fingerprint: "fingerprint",
            currentProgression: 1,
            chunks: [
                ReaderBookKnowledgeSnapshot.Chunk(
                    ordinal: 0,
                    resourceId: "text",
                    resourceTitle: nil,
                    text: "Complete text",
                    positionStart: 0,
                    positionEnd: 13,
                    progressionStart: 0,
                    progressionEnd: 1
                )
            ],
            annotations: [
                ReaderBookKnowledgeSnapshot.Annotation(
                    id: annotationID,
                    selectedText: "Selected text",
                    note: note,
                    resourceId: "text",
                    position: 0,
                    progression: 0.5,
                    locator: ReaderLocator(
                        publicationFingerprint: "fingerprint",
                        resourceID: "text",
                        position: 0,
                        progression: 0.5
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )
    }
}

private final class CredentialStoreStub: ReaderCredentialStoring, @unchecked Sendable {
    private var session: ReaderAuthSession?

    init(session: ReaderAuthSession? = nil) {
        self.session = session
    }

    func load() throws -> ReaderAuthSession? { session }
    func save(_ session: ReaderAuthSession) throws { self.session = session }
    func remove() throws { session = nil }
}

private actor BackendStub: ReaderBackendServicing {
    let signInSession: ReaderAuthSession
    let refreshedSession: ReaderAuthSession
    let streamEvents: [ReaderChatStreamEvent]
    private(set) var lastAnswerToken: String?
    private(set) var annotationBatchSizes: [Int] = []
    let syncedAnnotations: [ReaderAnnotation]
    private(set) var ingestionCount = 0
    private(set) var fileSyncs: [ReaderLibraryFileUpload] = []
    let ingestionDelay: Duration
    let fileSyncDelay: Duration

    init(
        signInSession: ReaderAuthSession,
        refreshedSession: ReaderAuthSession? = nil,
        ingestionDelay: Duration = .zero,
        fileSyncDelay: Duration = .zero,
        streamEvents: [ReaderChatStreamEvent] = [
            .delta("Answer"),
            .complete(model: "test", finishReason: "stop")
        ],
        syncedAnnotations: [ReaderAnnotation] = []
    ) {
        self.signInSession = signInSession
        self.refreshedSession = refreshedSession ?? signInSession
        self.ingestionDelay = ingestionDelay
        self.fileSyncDelay = fileSyncDelay
        self.streamEvents = streamEvents
        self.syncedAnnotations = syncedAnnotations
    }

    func signIn(email: String, password: String) async throws -> ReaderAuthSession {
        signInSession
    }

    func signUp(email: String, password: String) async throws -> ReaderSignUpResult {
        ReaderSignUpResult(
            session: signInSession,
            user: signInSession.user,
            requiresEmailConfirmation: false
        )
    }

    func refreshSession(refreshToken: String) async throws -> ReaderAuthSession {
        refreshedSession
    }

    func answerHighlightQuestion(
        _ request: HighlightQuestionRequest,
        accessToken: String
    ) async throws -> HighlightQuestionAnswer {
        HighlightQuestionAnswer(text: "Answer", model: "test")
    }

    func generateChatTitle(
        _ request: ReaderChatTitleRequest,
        accessToken: String
    ) async throws -> ReaderChatTitle {
        ReaderChatTitle(title: "test conversation", model: "test")
    }

    func streamChat(
        _ request: ReaderChatRequest,
        accessToken: String
    ) async throws -> AsyncThrowingStream<ReaderChatStreamEvent, Error> {
        lastAnswerToken = accessToken
        return AsyncThrowingStream { continuation in
            for event in streamEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func syncAnnotations(
        _ annotations: [ReaderAnnotation],
        accessToken: String
    ) async throws -> [ReaderAnnotation] {
        annotationBatchSizes.append(annotations.count)
        return syncedAnnotations
    }

    func ingestBookKnowledge(
        _ request: ReaderBookKnowledgeIngestionRequest,
        accessToken: String
    ) async throws {
        ingestionCount += 1
        if ingestionDelay > .zero {
            try await Task.sleep(for: ingestionDelay)
        }
    }

    func syncLibraryFile(
        _ upload: ReaderLibraryFileUpload,
        accessToken: String
    ) async throws {
        fileSyncs.append(upload)
        if fileSyncDelay > .zero {
            try await Task.sleep(for: fileSyncDelay)
        }
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import Reader

final class ReaderAssistantMessageTests: XCTestCase {
    func testDisplayTextRemovesMarkdownMarkers() {
        let message = ReaderAssistantMessage(
            role: .assistant,
            text: "The **selected passage** is complete."
        )

        XCTAssertEqual(
            String(message.displayText.characters),
            "The selected passage is complete."
        )
    }

    func testPersistedMessageWithoutAttachmentsStillDecodes() throws {
        let json = """
        {
          "id": "1D941901-359F-4A23-B1D3-6F46DD435D0B",
          "role": { "reader": {} },
          "text": "An older message"
        }
        """

        let message = try JSONDecoder().decode(
            ReaderAssistantMessage.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(message.text, "An older message")
        XCTAssertTrue(message.attachments.isEmpty)
    }

    @MainActor
    func testLoadingBubbleRendersAtCodexReferenceSize() throws {
        let renderer = ImageRenderer(
            content: ReaderAssistantLoadingBubble(phaseOverride: 0)
        )
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            return XCTFail("Expected the loading bubble to render")
        }

        XCTAssertEqual(image.size, NSSize(width: 32, height: 32))
        let attachment = XCTAttachment(image: image)
        attachment.name = "Reader chat loading bubble at 2x"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLoadingBubbleAnimationMatchesCodexWave() throws {
        XCTAssertEqual(
            ReaderAssistantLoadingBubble.verticalOffset(for: 0, phase: 0.20),
            2.5,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ReaderAssistantLoadingBubble.verticalOffset(for: 0, phase: 0.50),
            -4,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ReaderAssistantLoadingBubble.verticalOffset(for: 1, phase: 0.60),
            -4,
            accuracy: 0.01
        )
        XCTAssertEqual(
            ReaderAssistantLoadingBubble.verticalOffset(for: 2, phase: 0.85),
            0,
            accuracy: 0.01
        )

        let renderer = ImageRenderer(
            content: HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { frame in
                    ReaderAssistantLoadingBubble(
                        phaseOverride: Double(frame) / 10
                    )
                }
            }
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size, NSSize(width: 320, height: 32))
        let attachment = XCTAttachment(image: image)
        attachment.name = "Reader chat loading motion at 10 fps"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class ReaderAssistantSessionTests: XCTestCase {
    @MainActor
    func testContextPageNumberLayoutKeepsFourDigitsUngrouped() {
        XCTAssertEqual(
            ReaderContextPageNumberLayout.value(for: 1_024) as String,
            "1024"
        )
        XCTAssertEqual(
            ReaderContextPageNumberLayout.fontSize(forDigitCount: 4),
            3.8
        )
    }

    func testPageSpoilerSafeAndWholeBookScopesAreManuallySelectable() {
        XCTAssertEqual(
            ReaderContextScope.userSelectableScopes,
            [.page, .upToHere, .wholeBook]
        )
        XCTAssertEqual(
            ReaderContextScope.allCases.map(\.assetName),
            [
                "ReaderContextSelection",
                "ReaderContextPage",
                "ReaderContextUpToHere",
                "ReaderContextWholeBook"
            ]
        )
    }

    func testPageScopeCanBeChosenWithoutASelection() {
        let session = ReaderAssistantSession(source: makeSource())

        session.setContextScope(.page)

        XCTAssertFalse(session.isPassageAttached)
        XCTAssertEqual(session.contextScope, .page)
        XCTAssertEqual(session.effectiveContextScope, .page)
    }

    func testUpToHereUsesTheCurrentBookPageNumber() {
        let session = ReaderAssistantSession()
        session.attachBookKnowledge(
            ReaderBookKnowledgeSnapshot(
                publicationID: UUID(),
                title: "The Test Book",
                author: "A. Reader",
                format: .epub,
                fingerprint: "book-fingerprint",
                currentProgression: 0.41,
                currentPageNumber: 84,
                chunks: [],
                annotations: []
            )
        )

        XCTAssertEqual(session.currentPageNumber, 84)
    }

    func testPDFSelectionFallsBackToItsExactPageNumber() {
        let source = HighlightQuestionDraft(
            publicationTitle: "The Test Book",
            publicationAuthor: "A. Reader",
            publicationFormat: .pdf,
            selection: ReaderSelection(
                locator: ReaderLocator(
                    publicationFingerprint: "book-fingerprint",
                    resourceID: "page-83",
                    position: 83,
                    progression: 0.41
                ),
                selectedText: "Call me Ishmael."
            ),
            context: ReaderSelectionContext(before: "", after: "")
        )

        XCTAssertEqual(ReaderAssistantSession(source: source).currentPageNumber, 84)
    }

    func testSelectionTemporarilyOverridesSpoilerSafeDefault() {
        let session = ReaderAssistantSession(source: makeSource())

        XCTAssertEqual(session.contextScope, .upToHere)
        XCTAssertEqual(session.effectiveContextScope, .passage)
        XCTAssertEqual(session.effectiveContextScope.title, "selection")

        session.detachPassage()

        XCTAssertEqual(session.contextScope, .upToHere)
        XCTAssertEqual(session.effectiveContextScope, .upToHere)
    }

    func testNewSelectionUpdatesAnExistingConversationContext() {
        let session = ReaderAssistantSession()
        let source = makeSource()

        session.attachSelection(source)

        XCTAssertEqual(session.source, source)
        XCTAssertTrue(session.isPassageAttached)
        XCTAssertEqual(session.contextScope, .upToHere)
        XCTAssertEqual(session.effectiveContextScope, .passage)
    }

    func testSendKeepsEmptyAssistantSlotUntilFirstToken() {
        let backend = AssistantBackendStub(
            events: [],
            suspendsAfterEvents: true
        )
        let account = makeAccount(backend: backend)
        let session = ReaderAssistantSession()
        session.draftQuestion = "Take a moment before answering"

        session.send(using: account)

        XCTAssertTrue(session.isAnswering)
        XCTAssertEqual(session.messages.map(\.role), [.reader, .assistant])
        XCTAssertEqual(session.messages.last?.text, "")

        session.stopAnswering()
        XCTAssertEqual(session.messages.map(\.role), [.reader])
    }

    func testGeneralConversationStreamsWithoutPassageContext() async throws {
        let backend = AssistantBackendStub(events: [
            .delta("Hello"),
            .delta(" there."),
            .complete(model: "test", finishReason: "stop")
        ])
        let account = makeAccount(backend: backend)
        let session = ReaderAssistantSession()
        session.draftQuestion = "Can we talk about this book?"

        session.send(using: account)
        await waitForResponse(in: session)

        XCTAssertEqual(session.messages.map(\.role), [.reader, .assistant])
        XCTAssertEqual(session.messages.last?.text, "Hello there.")
        let request = await backend.lastRequest
        XCTAssertNil(request?.context)
    }

    func testPassageQuoteAppearsOnFirstReaderMessageOnly() async throws {
        let backend = AssistantBackendStub(events: [
            .delta("A grounded response."),
            .complete(model: "test", finishReason: "stop")
        ])
        let account = makeAccount(backend: backend)
        let session = ReaderAssistantSession(source: makeSource())
        var completedConversations: [ReaderConversation] = []
        session.onConversationCompleted = { completedConversations.append($0) }
        session.draftQuestion = "Why this image?"

        session.send(using: account)
        XCTAssertFalse(session.isPassageAttached)
        await waitForResponse(in: session)
        let selectionRequest = await backend.lastRequest
        XCTAssertEqual(selectionRequest?.context?.scope, .passage)
        XCTAssertEqual(session.effectiveContextScope, .upToHere)

        session.draftQuestion = "Is the uncertainty intentional?"
        session.send(using: account)
        await waitForResponse(in: session)

        let readerMessages = session.messages.filter { $0.role == .reader }
        XCTAssertNotNil(readerMessages.first?.passage)
        XCTAssertNil(readerMessages.last?.passage)
        let request = await backend.lastRequest
        XCTAssertNotNil(request?.context)
        // With no searchable book snapshot, the request safely falls back to
        // the only local context available: the original selection.
        XCTAssertEqual(request?.context?.scope, .passage)
        XCTAssertEqual(completedConversations.count, 2)
        XCTAssertEqual(
            completedConversations.last?.question,
            "Is the uncertainty intentional?"
        )
    }

    func testStopRetainsThePartialStreamedResponse() async throws {
        let backend = AssistantBackendStub(
            events: [.delta("A partial thought")],
            suspendsAfterEvents: true
        )
        let account = makeAccount(backend: backend)
        let session = ReaderAssistantSession()
        session.draftQuestion = "Keep the part I already received"

        session.send(using: account)
        for _ in 0..<100 {
            if session.messages.last?.text == "A partial thought" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        session.stopAnswering()

        XCTAssertFalse(session.isAnswering)
        XCTAssertEqual(session.messages.last?.text, "A partial thought")
    }

    func testFirstQuestionNamesConversationWithoutBlockingResponse() async throws {
        let backend = AssistantBackendStub(events: [
            .delta("Yes."),
            .complete(model: "test", finishReason: "stop")
        ])
        let account = makeAccount(backend: backend)
        let session = ReaderAssistantSession()
        var renamedTo: String?
        session.onTitleChanged = { renamedTo = $0 }
        session.draftQuestion = "Is the confusion intentional?"

        session.send(using: account)
        await waitForResponse(in: session)
        for _ in 0..<100 where session.generatedTitle == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(session.title, "intentional confusion")
        XCTAssertEqual(renamedTo, "intentional confusion")
    }

    func testUntitledConversationHasNoDisplayTitle() {
        let session = ReaderAssistantSession()

        XCTAssertNil(session.displayTitle)
        XCTAssertEqual(session.title, "new conversation")
    }

    func testAttachmentIsSentAndClearedFromComposer() async throws {
        let backend = AssistantBackendStub(events: [
            .delta("I can see it."),
            .complete(model: "test", finishReason: "stop")
        ])
        let account = makeAccount(backend: backend)
        let session = ReaderAssistantSession()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "reader-chat-test.txt")
        try Data("notes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        session.addAttachments(from: [url])
        session.draftQuestion = "What do these notes say?"
        session.send(using: account)
        await waitForResponse(in: session)

        XCTAssertTrue(session.pendingAttachments.isEmpty)
        let request = await backend.lastRequest
        XCTAssertEqual(request?.messages.first?.attachments.count, 1)
        XCTAssertEqual(
            request?.messages.first?.attachments.first?.filename,
            "reader-chat-test.txt"
        )
    }

    func testBookKnowledgeBecomesCloudSearchableAndRecordsEvidence() async throws {
        let backend = AssistantBackendStub(events: [
            .delta("The promise changes here."),
            .evidence("searched 3 passages · searched 1 note"),
            .complete(model: "test", finishReason: "stop")
        ])
        let account = makeAccount(backend: backend)
        let session = ReaderAssistantSession()
        let publicationID = UUID()
        session.attachBookKnowledge(
            ReaderBookKnowledgeSnapshot(
                publicationID: publicationID,
                title: "The Test Book",
                author: "A. Reader",
                format: .epub,
                fingerprint: "book-fingerprint",
                currentProgression: 0.41,
                chunks: [
                    ReaderBookKnowledgeSnapshot.Chunk(
                        ordinal: 0,
                        resourceId: "chapter-1.xhtml",
                        resourceTitle: "Chapter 1",
                        text: "A promise is made and later revised.",
                        positionStart: 0,
                        positionEnd: 36,
                        progressionStart: 0,
                        progressionEnd: 0.2
                    )
                ],
                annotations: []
            )
        )
        session.draftQuestion = "Where does the promise change?"

        session.send(using: account)
        await waitForResponse(in: session)

        let request = await backend.lastRequest
        XCTAssertEqual(request?.context?.publication.id, publicationID)
        XCTAssertEqual(request?.context?.publication.textAccess, .cloudSearchable)
        XCTAssertEqual(request?.context?.scope, .upToHere)
        XCTAssertEqual(request?.context?.currentProgression, 0.41)
        XCTAssertEqual(session.processingStatus, .parsed)
        XCTAssertEqual(
            session.messages.last?.evidenceLabel,
            "searched 3 passages · searched 1 note"
        )
        let ingestionCount = await backend.ingestionCount
        XCTAssertEqual(ingestionCount, 1)
    }

    private func makeAccount(backend: AssistantBackendStub) -> ReaderAccountModel {
        let authSession = ReaderAuthSession(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: 4_000_000_000,
            user: ReaderAuthUser(id: "reader", email: "reader@example.com")
        )
        return ReaderAccountModel(
            backend: backend,
            credentialStore: AssistantCredentialStore(session: authSession)
        )
    }

    private func waitForResponse(in session: ReaderAssistantSession) async {
        for _ in 0..<100 {
            if !session.isAnswering { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for streamed response")
    }

    private func makeSource() -> HighlightQuestionDraft {
        HighlightQuestionDraft(
            publicationTitle: "Moby-Dick",
            publicationAuthor: "Herman Melville",
            publicationFormat: .epub,
            selection: ReaderSelection(
                locator: ReaderLocator(
                    publicationFingerprint: "moby",
                    resourceID: "chapter-3.xhtml",
                    position: 47,
                    progression: 0.12
                ),
                selectedText: "diligent study and a series of systematic visits to it"
            ),
            context: ReaderSelectionContext(before: "Before", after: "After")
        )
    }
}

private final class AssistantCredentialStore: ReaderCredentialStoring, @unchecked Sendable {
    private var session: ReaderAuthSession?

    init(session: ReaderAuthSession?) {
        self.session = session
    }

    func load() throws -> ReaderAuthSession? { session }
    func save(_ session: ReaderAuthSession) throws { self.session = session }
    func remove() throws { session = nil }
}

private actor AssistantBackendStub: ReaderBackendServicing {
    private let events: [ReaderChatStreamEvent]
    private let suspendsAfterEvents: Bool
    private(set) var lastRequest: ReaderChatRequest?
    private(set) var ingestionCount = 0

    init(
        events: [ReaderChatStreamEvent],
        suspendsAfterEvents: Bool = false
    ) {
        self.events = events
        self.suspendsAfterEvents = suspendsAfterEvents
    }

    func signIn(email: String, password: String) async throws -> ReaderAuthSession {
        throw ReaderBackendError.invalidResponse
    }

    func signUp(email: String, password: String) async throws -> ReaderSignUpResult {
        throw ReaderBackendError.invalidResponse
    }

    func refreshSession(refreshToken: String) async throws -> ReaderAuthSession {
        throw ReaderBackendError.invalidResponse
    }

    func answerHighlightQuestion(
        _ request: HighlightQuestionRequest,
        accessToken: String
    ) async throws -> HighlightQuestionAnswer {
        throw ReaderBackendError.invalidResponse
    }

    func syncAnnotations(
        _ annotations: [ReaderAnnotation],
        accessToken: String
    ) async throws -> [ReaderAnnotation] {
        annotations
    }

    func generateChatTitle(
        _ request: ReaderChatTitleRequest,
        accessToken: String
    ) async throws -> ReaderChatTitle {
        ReaderChatTitle(title: "intentional confusion", model: "test")
    }

    func streamChat(
        _ request: ReaderChatRequest,
        accessToken: String
    ) async throws -> AsyncThrowingStream<ReaderChatStreamEvent, Error> {
        lastRequest = request
        let events = events
        guard suspendsAfterEvents else {
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    continuation.yield(event)
                }
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func ingestBookKnowledge(
        _ request: ReaderBookKnowledgeIngestionRequest,
        accessToken: String
    ) async throws {
        ingestionCount += 1
    }

    func syncLibraryFile(
        _ upload: ReaderLibraryFileUpload,
        accessToken: String
    ) async throws {}
}

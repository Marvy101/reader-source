import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ReaderAssistantSession {
    private(set) var source: HighlightQuestionDraft?
    var draftQuestion = "" { didSet { persistIfNeeded() } }
    private(set) var messages: [ReaderAssistantMessage] = [] {
        didSet { persistIfNeeded() }
    }
    private(set) var isAnswering = false
    private(set) var isPassageAttached: Bool
    private(set) var contextScope: ReaderContextScope
    private(set) var textAccess: PublicationTextAccess
    private(set) var processingStatus: PublicationProcessingStatus
    private(set) var pendingAttachments: [ReaderChatAttachment] = [] {
        didSet { persistIfNeeded() }
    }
    private(set) var generatedTitle: String? = nil {
        didSet { persistIfNeeded() }
    }
    var errorMessage: String?
    var onConversationCompleted: ((ReaderConversation) -> Void)?
    @ObservationIgnored var onStateChanged: (() -> Void)?
    @ObservationIgnored var onTitleChanged: ((String) -> Void)?
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    @ObservationIgnored private var titleTask: Task<Void, Never>?
    @ObservationIgnored private var knowledgePreparationTask: Task<Bool, Never>?
    @ObservationIgnored private var suppressPersistence = false
    @ObservationIgnored private var bookKnowledge: ReaderBookKnowledgeSnapshot?

    init(source: HighlightQuestionDraft? = nil) {
        self.source = source
        isPassageAttached = source != nil
        contextScope = .upToHere
        textAccess = source == nil ? .unavailable : .localOnly
        processingStatus = .notStarted
    }

    init(snapshot: ReaderAssistantSessionSnapshot) {
        source = snapshot.source
        draftQuestion = snapshot.draftQuestion
        messages = snapshot.messages.filter {
            $0.role != .assistant || !$0.text.isEmpty
        }
        isPassageAttached = snapshot.isPassageAttached ?? (snapshot.source != nil)
        pendingAttachments = snapshot.pendingAttachments ?? []
        generatedTitle = snapshot.generatedTitle
        let restoredScope = snapshot.contextScope ?? .upToHere
        contextScope = restoredScope == .passage ? .upToHere : restoredScope
        textAccess = snapshot.source == nil ? .unavailable : .localOnly
        processingStatus = .notStarted
    }

    deinit {
        responseTask?.cancel()
        titleTask?.cancel()
        knowledgePreparationTask?.cancel()
    }

    var snapshot: ReaderAssistantSessionSnapshot {
        ReaderAssistantSessionSnapshot(
            source: source,
            draftQuestion: draftQuestion,
            messages: messages.filter {
                $0.role != .assistant || !$0.text.isEmpty
            },
            isPassageAttached: isPassageAttached,
            pendingAttachments: pendingAttachments,
            generatedTitle: generatedTitle,
            contextScope: contextScope
        )
    }

    var title: String {
        displayTitle ?? "new conversation"
    }

    var displayTitle: String? {
        generatedTitle ?? source?.publicationTitle.lowercased()
    }

    var passageQuote: ReaderPassageQuote? {
        source.map(ReaderPassageQuote.init)
    }

    var canAttachPassage: Bool {
        source != nil
    }

    var canReceiveSelection: Bool {
        !isAnswering
    }

    var canSend: Bool {
        !draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isAnswering
    }

    var contextScopeLabel: String? {
        guard bookKnowledge != nil || source != nil else { return nil }
        if processingStatus == .preparing {
            return "preparing this book"
        }
        if processingStatus == .failed {
            return source == nil
                ? "book search unavailable"
                : "selected passage · book search unavailable"
        }
        let scope = effectiveContextScope
        return "\(scope.title) · \(scope.detail)"
    }

    var effectiveContextScope: ReaderContextScope {
        isPassageAttached ? .passage : contextScope
    }

    var currentPageNumber: Int? {
        if let currentPageNumber = bookKnowledge?.currentPageNumber {
            return currentPageNumber
        }
        guard
            source?.publicationFormat == .pdf,
            let resourceID = source?.selection.locator.resourceID,
            resourceID.hasPrefix("page-"),
            let pageIndex = Int(resourceID.dropFirst("page-".count))
        else {
            return nil
        }
        return pageIndex + 1
    }

    func attachBookKnowledge(_ snapshot: ReaderBookKnowledgeSnapshot) {
        let existing = bookKnowledge
        let requiresPreparation = existing?.fingerprint != snapshot.fingerprint
            || existing?.annotations.map(\.id) != snapshot.annotations.map(\.id)
        bookKnowledge = snapshot
        guard requiresPreparation else { return }
        textAccess = .localOnly
        processingStatus = .notStarted
    }

    func setContextScope(_ scope: ReaderContextScope) {
        guard !isAnswering, scope != .passage else { return }
        isPassageAttached = false
        contextScope = scope
        onStateChanged?()
    }

    func attachSelection(_ selectionSource: HighlightQuestionDraft) {
        guard canReceiveSelection else { return }
        source = selectionSource
        isPassageAttached = true
        contextScope = .upToHere
        errorMessage = nil
        if bookKnowledge == nil {
            textAccess = .localOnly
            processingStatus = .notStarted
        }
        onStateChanged?()
    }

    @discardableResult
    func prepareBookKnowledge(using account: ReaderAccountModel) async -> Bool {
        guard let knowledge = bookKnowledge else { return false }
        if processingStatus == .parsed { return true }
        if let knowledgePreparationTask {
            return await knowledgePreparationTask.value
        }

        processingStatus = .preparing
        let task = Task { [account] in
            do {
                try await account.prepareBookKnowledge(knowledge)
                try Task.checkCancellation()
                return true
            } catch {
                return false
            }
        }
        knowledgePreparationTask = task
        let prepared = await task.value
        knowledgePreparationTask = nil
        textAccess = prepared ? .cloudSearchable : .localOnly
        processingStatus = prepared ? .parsed : .failed
        return prepared
    }

    func togglePassageAttachment() {
        guard canAttachPassage else { return }
        isPassageAttached.toggle()
        if !isPassageAttached {
            contextScope = .upToHere
        }
        onStateChanged?()
    }

    func detachPassage() {
        guard isPassageAttached else { return }
        isPassageAttached = false
        contextScope = .upToHere
        onStateChanged?()
    }

    func addAttachments(from urls: [URL]) {
        guard !isAnswering else { return }
        errorMessage = nil

        do {
            let additions = try urls.map(loadAttachment)
            guard pendingAttachments.count + additions.count <= 4 else {
                throw AttachmentError.tooMany
            }
            let totalBytes = (pendingAttachments + additions)
                .reduce(0) { $0 + $1.byteCount }
            guard totalBytes <= 2_500_000 else {
                throw AttachmentError.tooLarge
            }
            pendingAttachments.append(contentsOf: additions)
        } catch {
            errorMessage = error.localizedDescription
            onStateChanged?()
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func resetConversation() {
        stopAnswering()
        draftQuestion = ""
        messages = []
        errorMessage = nil
        isPassageAttached = source != nil
        contextScope = .upToHere
        pendingAttachments = []
        generatedTitle = nil
        titleTask?.cancel()
        titleTask = nil
        onStateChanged?()
    }

    func send(using account: ReaderAccountModel) {
        let question = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }

        draftQuestion = ""
        errorMessage = nil
        let isFirstQuestion = !messages.contains { $0.role == .reader }
        let quote = shouldShowPassageOnNextMessage ? passageQuote : nil
        let requestScope = effectiveContextScope
        let usesPassageContext = isPassageAttached
            || messages.contains { $0.passage != nil }
        let attachments = pendingAttachments
        isPassageAttached = false
        contextScope = .upToHere
        pendingAttachments = []
        messages.append(
            ReaderAssistantMessage(
                role: .reader,
                text: question,
                passage: quote,
                attachments: attachments
            )
        )
        let responseID = UUID()

        suppressPersistence = true
        isAnswering = true
        messages.append(
            ReaderAssistantMessage(
                id: responseID,
                role: .assistant,
                text: ""
            )
        )

        if isFirstQuestion, generatedTitle == nil {
            generateTitle(for: question, using: account)
        }

        responseTask = Task { [weak self, account] in
            guard let self else { return }
            if self.bookKnowledge != nil {
                _ = await self.prepareBookKnowledge(using: account)
                guard !Task.isCancelled else {
                    self.finishStreaming(removeEmptyResponse: true)
                    return
                }
            }
            let request = ReaderChatRequest(
                messages: self.messages.filter { !$0.text.isEmpty },
                source: usesPassageContext ? self.source : nil,
                knowledge: self.bookKnowledge,
                scope: requestScope,
                textAccess: self.textAccess
            )
            await self.consume(
                request,
                question: question,
                responseID: responseID,
                using: account
            )
        }
    }

    func stopAnswering() {
        responseTask?.cancel()
        responseTask = nil
        finishStreaming(removeEmptyResponse: true)
    }

    private var shouldShowPassageOnNextMessage: Bool {
        isPassageAttached && !messages.contains { $0.passage != nil }
    }

    private func generateTitle(
        for firstMessage: String,
        using account: ReaderAccountModel
    ) {
        titleTask?.cancel()
        titleTask = Task { [weak self, account] in
            guard let self else { return }
            do {
                let response = try await account.generateChatTitle(
                    firstMessage: firstMessage
                )
                try Task.checkCancellation()
                let title = response.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !title.isEmpty else { return }
                generatedTitle = title
                onTitleChanged?(title)
            } catch {
                // Naming is non-critical and must never interrupt the chat.
            }
            titleTask = nil
        }
    }

    private func loadAttachment(from url: URL) throws -> ReaderChatAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let values = try? url.resourceValues(
            forKeys: [.contentTypeKey, .fileSizeKey]
        )
        if let fileSize = values?.fileSize, fileSize > 2_500_000 {
            throw AttachmentError.tooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let contentType = values?.contentType
        let extensionName = url.pathExtension.lowercased()

        let kind: ReaderChatAttachment.Kind
        let mediaType: String
        if contentType?.conforms(to: .pdf) == true {
            kind = .pdf
            mediaType = "application/pdf"
        } else if contentType?.conforms(to: .image) == true {
            kind = .image
            switch extensionName {
            case "jpg", "jpeg": mediaType = "image/jpeg"
            case "png": mediaType = "image/png"
            case "gif": mediaType = "image/gif"
            case "webp": mediaType = "image/webp"
            default: throw AttachmentError.unsupported
            }
        } else if contentType?.conforms(to: .text) == true {
            kind = .text
            switch extensionName {
            case "md", "markdown": mediaType = "text/markdown"
            case "csv": mediaType = "text/csv"
            default: mediaType = "text/plain"
            }
        } else {
            throw AttachmentError.unsupported
        }

        return ReaderChatAttachment(
            kind: kind,
            filename: url.lastPathComponent,
            mediaType: mediaType,
            data: data.base64EncodedString()
        )
    }

    private func consume(
        _ request: ReaderChatRequest,
        question: String,
        responseID: UUID,
        using account: ReaderAccountModel
    ) async {
        do {
            let stream = try await account.streamChat(request)
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .delta(let text):
                    append(text, to: responseID)
                case .evidence(let label):
                    setEvidence(label, on: responseID)
                case .complete:
                    break
                }
            }
            try Task.checkCancellation()
            recordCompletedConversation(
                question: question,
                responseID: responseID
            )
            finishStreaming(removeEmptyResponse: true)
        } catch is CancellationError {
            finishStreaming(removeEmptyResponse: true)
        } catch {
            errorMessage = error.localizedDescription
            finishStreaming(removeEmptyResponse: true)
        }
    }

    private func append(_ text: String, to messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].text.append(text)
    }

    private func setEvidence(_ label: String, on messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        messages[index].evidenceLabel = label
    }

    private func recordCompletedConversation(
        question: String,
        responseID: UUID
    ) {
        guard
            let source,
            let answer = messages.first(where: { $0.id == responseID })?.text,
            !answer.isEmpty
        else { return }

        onConversationCompleted?(
            ReaderConversation(
                publicationID: source.publicationID,
                publicationTitle: source.publicationTitle,
                question: question,
                answer: answer,
                locator: source.selection.locator
            )
        )
    }

    private func finishStreaming(removeEmptyResponse: Bool) {
        if removeEmptyResponse {
            messages.removeAll {
                $0.role == .assistant && $0.text.isEmpty
            }
        }
        isAnswering = false
        responseTask = nil
        suppressPersistence = false
        onStateChanged?()
    }

    private func persistIfNeeded() {
        guard !suppressPersistence else { return }
        onStateChanged?()
    }
}

private enum AttachmentError: LocalizedError {
    case tooMany
    case tooLarge
    case unsupported

    var errorDescription: String? {
        switch self {
        case .tooMany:
            "Attach up to four files at a time."
        case .tooLarge:
            "Attachments must be 2.5 MB or less in total."
        case .unsupported:
            "Choose a PNG, JPEG, GIF, WebP, PDF, or text document."
        }
    }
}

struct ReaderAssistantSessionSnapshot: Codable, Equatable, Sendable {
    let source: HighlightQuestionDraft?
    let draftQuestion: String
    let messages: [ReaderAssistantMessage]
    let isPassageAttached: Bool?
    let pendingAttachments: [ReaderChatAttachment]?
    let generatedTitle: String?
    let contextScope: ReaderContextScope?

    init(
        source: HighlightQuestionDraft?,
        draftQuestion: String,
        messages: [ReaderAssistantMessage],
        isPassageAttached: Bool? = nil,
        pendingAttachments: [ReaderChatAttachment]? = nil,
        generatedTitle: String? = nil,
        contextScope: ReaderContextScope? = nil
    ) {
        self.source = source
        self.draftQuestion = draftQuestion
        self.messages = messages
        self.isPassageAttached = isPassageAttached
        self.pendingAttachments = pendingAttachments
        self.generatedTitle = generatedTitle
        self.contextScope = contextScope
    }
}

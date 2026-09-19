import Foundation

struct HighlightQuestionDraft: Codable, Hashable, Sendable {
    let publicationID: UUID?
    let publicationTitle: String
    let publicationAuthor: String
    let publicationFormat: PublicationFormat
    let selection: ReaderSelection
    let context: ReaderSelectionContext

    init(
        publicationID: UUID? = nil,
        publicationTitle: String,
        publicationAuthor: String,
        publicationFormat: PublicationFormat,
        selection: ReaderSelection,
        context: ReaderSelectionContext
    ) {
        self.publicationID = publicationID
        self.publicationTitle = publicationTitle
        self.publicationAuthor = publicationAuthor
        self.publicationFormat = publicationFormat
        self.selection = selection
        self.context = context
    }
}

struct ReaderRewriteCommand: Equatable, Sendable {
    let instruction: String?
    let currentDraft: String?

    init(
        instruction: String? = nil,
        currentDraft: String? = nil
    ) {
        let normalizedInstruction = instruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.instruction = normalizedInstruction?.isEmpty == false
            ? normalizedInstruction
            : nil
        let normalizedDraft = currentDraft?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentDraft = normalizedDraft?.isEmpty == false
            ? normalizedDraft
            : nil
    }

    var question: String {
        guard let instruction else {
            return "Rewrite this passage in simpler terms. Return only the rewritten passage."
        }

        let draftSection = currentDraft.map {
            """

            Current rewrite:
            <current_rewrite>
            \($0)
            </current_rewrite>
            """
        } ?? ""

        return """
        Rewrite the selected passage using this one-time instruction:
        <instruction>
        \(instruction)
        </instruction>\(draftSection)

        Return only the revised passage. Do not describe the changes.
        """
    }
}

struct HighlightQuestionRequest: Encodable, Sendable {
    struct HistoryItem: Encodable, Sendable {
        let role: String
        let text: String
    }

    struct Publication: Encodable, Sendable {
        let title: String
        let author: String?
        let format: String
    }

    struct Selection: Encodable, Sendable {
        let text: String
        let contextBefore: String
        let contextAfter: String
        let resourceId: String
        let progression: Double
    }

    let question: String
    let history: [HistoryItem]
    let publication: Publication
    let selection: Selection

    init(
        question: String,
        draft: HighlightQuestionDraft,
        history: [ReaderAssistantMessage] = []
    ) {
        self.question = question
        self.history = history.suffix(8).map { message in
            HistoryItem(
                role: message.role == .reader ? "reader" : "assistant",
                text: String(message.text.prefix(4_000))
            )
        }
        publication = Publication(
            title: draft.publicationTitle,
            author: draft.publicationAuthor.isEmpty ? nil : draft.publicationAuthor,
            format: draft.publicationFormat.rawValue
        )
        selection = Selection(
            text: draft.selection.selectedText,
            contextBefore: draft.context.before,
            contextAfter: draft.context.after,
            resourceId: draft.selection.locator.resourceID,
            progression: draft.selection.locator.progression
        )
    }
}

struct HighlightQuestionAnswer: Equatable, Sendable {
    let text: String
    let model: String
}

struct ReaderPassageQuote: Codable, Equatable, Sendable {
    let text: String
    let source: String

    init(draft: HighlightQuestionDraft) {
        text = draft.selection.selectedText
        let resource = draft.selection.locator.resourceID
            .replacingOccurrences(of: ".xhtml", with: "")
            .replacingOccurrences(of: "-", with: " ")
        source = resource.isEmpty
            ? draft.publicationTitle
            : "\(draft.publicationTitle) · \(resource)"
    }
}

enum PublicationTextAccess: String, Codable, Equatable, Sendable {
    case cloudSearchable
    case localOnly
    case restricted
    case unavailable
}

enum PublicationProcessingStatus: String, Codable, Equatable, Sendable {
    case notStarted
    case preparing
    case parsed
    case failed
}

enum ReaderContextScope: String, Codable, CaseIterable, Equatable, Sendable {
    case passage
    case page
    case upToHere
    case wholeBook

    static let userSelectableScopes: [ReaderContextScope] = [
        .page,
        .upToHere,
        .wholeBook
    ]

    var title: String {
        switch self {
        case .passage: "selection"
        case .page: "this page"
        case .upToHere: "up to here"
        case .wholeBook: "whole book"
        }
    }

    var detail: String {
        switch self {
        case .passage: "selected text + nearby context"
        case .page: "the current page"
        case .upToHere: "no spoilers past your place"
        case .wholeBook: "may include spoilers"
        }
    }

    var assetName: String {
        switch self {
        case .passage: "ReaderContextSelection"
        case .page: "ReaderContextPage"
        case .upToHere: "ReaderContextUpToHere"
        case .wholeBook: "ReaderContextWholeBook"
        }
    }
}

struct ReaderBookKnowledgeSnapshot: Sendable {
    struct Chunk: Encodable, Sendable {
        let ordinal: Int
        let resourceId: String
        let resourceTitle: String?
        let text: String
        let positionStart: Int
        let positionEnd: Int
        let progressionStart: Double
        let progressionEnd: Double
    }

    struct Annotation: Encodable, Sendable {
        let id: UUID
        let selectedText: String
        let note: String?
        let resourceId: String
        let position: Int
        let progression: Double
        let locator: ReaderLocator
        let createdAt: Date
    }

    let publicationID: UUID
    let title: String
    let author: String
    let format: PublicationFormat
    let fingerprint: String
    let currentProgression: Double
    let currentPageNumber: Int?
    let chunks: [Chunk]
    let annotations: [Annotation]

    init(
        publicationID: UUID,
        title: String,
        author: String,
        format: PublicationFormat,
        fingerprint: String,
        currentProgression: Double,
        currentPageNumber: Int? = nil,
        chunks: [Chunk],
        annotations: [Annotation]
    ) {
        self.publicationID = publicationID
        self.title = title
        self.author = author
        self.format = format
        self.fingerprint = fingerprint
        self.currentProgression = currentProgression
        self.currentPageNumber = currentPageNumber
        self.chunks = chunks
        self.annotations = annotations
    }

    var characterCount: Int {
        chunks.reduce(0) { $0 + $1.text.count }
    }
}

struct ReaderBookKnowledgeIngestionRequest: Encodable, Sendable {
    let publicationID: UUID
    let title: String
    let author: String
    let format: PublicationFormat
    let fingerprint: String
    let chunks: [ReaderBookKnowledgeSnapshot.Chunk]
    let annotations: [ReaderBookKnowledgeSnapshot.Annotation]

    init(snapshot: ReaderBookKnowledgeSnapshot) {
        publicationID = snapshot.publicationID
        title = snapshot.title
        author = snapshot.author
        format = snapshot.format
        fingerprint = snapshot.fingerprint
        chunks = snapshot.chunks
        annotations = snapshot.annotations
    }
}

struct ReaderChatRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let text: String
        let attachments: [ReaderChatAttachment]
    }

    struct Context: Encodable, Sendable {
        struct Publication: Encodable, Sendable {
            let id: UUID?
            let title: String
            let author: String?
            let format: String
            let textAccess: PublicationTextAccess
        }

        struct Selection: Encodable, Sendable {
            let text: String
            let contextBefore: String
            let contextAfter: String
            let resourceId: String
            let progression: Double
        }

        let publication: Publication
        let scope: ReaderContextScope
        let currentProgression: Double
        let selection: Selection?
    }

    let messages: [Message]
    let context: Context?

    init(
        messages: [ReaderAssistantMessage],
        source: HighlightQuestionDraft?,
        knowledge: ReaderBookKnowledgeSnapshot? = nil,
        scope: ReaderContextScope = .passage,
        textAccess: PublicationTextAccess = .localOnly
    ) {
        self.messages = messages.suffix(16).map { message in
            Message(
                role: message.role == .reader ? "reader" : "assistant",
                text: String(message.text.prefix(4_000)),
                attachments: message.attachments
            )
        }
        if let knowledge {
            context = Context(
                publication: Context.Publication(
                    id: textAccess == .cloudSearchable
                        ? knowledge.publicationID
                        : nil,
                    title: knowledge.title,
                    author: knowledge.author.isEmpty
                        ? nil
                        : knowledge.author,
                    format: knowledge.format.rawValue,
                    textAccess: textAccess
                ),
                scope: scope,
                currentProgression: source?.selection.locator.progression
                    ?? knowledge.currentProgression,
                selection: source.map { draft in
                    Context.Selection(
                        text: draft.selection.selectedText,
                        contextBefore: draft.context.before,
                        contextAfter: draft.context.after,
                        resourceId: draft.selection.locator.resourceID,
                        progression: draft.selection.locator.progression
                    )
                }
            )
        } else if let source {
            context = Context(
                publication: Context.Publication(
                    id: nil,
                    title: source.publicationTitle,
                    author: source.publicationAuthor.isEmpty
                        ? nil
                        : source.publicationAuthor,
                    format: source.publicationFormat.rawValue,
                    textAccess: .localOnly
                ),
                scope: .passage,
                currentProgression: source.selection.locator.progression,
                selection: Context.Selection(
                    text: source.selection.selectedText,
                    contextBefore: source.context.before,
                    contextAfter: source.context.after,
                    resourceId: source.selection.locator.resourceID,
                    progression: source.selection.locator.progression
                )
            )
        } else {
            context = nil
        }
    }
}

struct ReaderChatTitleRequest: Encodable, Sendable {
    let firstMessage: String
}

struct ReaderChatTitle: Decodable, Equatable, Sendable {
    let title: String
    let model: String
}

struct ReaderChatAttachment: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image
        case pdf
        case text
    }

    let id: UUID
    let kind: Kind
    let filename: String
    let mediaType: String
    let data: String

    init(
        id: UUID = UUID(),
        kind: Kind,
        filename: String,
        mediaType: String,
        data: String
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mediaType = mediaType
        self.data = data
    }

    var byteCount: Int {
        Data(base64Encoded: data)?.count ?? 0
    }

    var systemImage: String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        }
    }
}

enum ReaderChatStreamEvent: Equatable, Sendable {
    case delta(String)
    case evidence(String)
    case complete(model: String, finishReason: String)
}

struct ReaderAssistantMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: Codable, Sendable {
        case reader
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    let passage: ReaderPassageQuote?
    let attachments: [ReaderChatAttachment]
    var evidenceLabel: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        passage: ReaderPassageQuote? = nil,
        attachments: [ReaderChatAttachment] = [],
        evidenceLabel: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.passage = passage
        self.attachments = attachments
        self.evidenceLabel = evidenceLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case passage
        case attachments
        case evidenceLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        passage = try container.decodeIfPresent(
            ReaderPassageQuote.self,
            forKey: .passage
        )
        attachments = try container.decodeIfPresent(
            [ReaderChatAttachment].self,
            forKey: .attachments
        ) ?? []
        evidenceLabel = try container.decodeIfPresent(
            String.self,
            forKey: .evidenceLabel
        )
    }

    var displayText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

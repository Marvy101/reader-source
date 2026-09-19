import Foundation

enum PublicationFormat: String, Codable, Hashable, Sendable {
    case pdf
    case epub
    case plainText

    var displayName: String {
        switch self {
        case .pdf:
            "PDF"
        case .epub:
            "EPUB"
        case .plainText:
            "TXT"
        }
    }
}

struct PublicationReference: Codable, Hashable, Sendable {
    let sourceURL: URL
    let format: PublicationFormat
    let fingerprint: String
    let coverURL: URL?
}

struct ReadingCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let selectableText = ReadingCapabilities(rawValue: 1 << 0)
    static let search = ReadingCapabilities(rawValue: 1 << 1)
    static let highlights = ReadingCapabilities(rawValue: 1 << 2)
    static let reflow = ReadingCapabilities(rawValue: 1 << 3)
    static let fixedPages = ReadingCapabilities(rawValue: 1 << 4)
    static let tableOfContents = ReadingCapabilities(rawValue: 1 << 5)
}

struct TextAnchor: Codable, Hashable, Sendable {
    let exact: String
    let prefix: String
    let suffix: String
}

struct ReaderRect: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ReaderViewportPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct ReaderAnnotationNoteRequest: Equatable, Sendable {
    let annotationID: UUID
    let viewportPoint: ReaderViewportPoint?
}

struct ReaderNotePlacement: Codable, Hashable, Sendable {
    let horizontalOffset: Double
    let verticalOffset: Double
}

struct ReaderAnnotationNotePlacementRequest: Equatable, Sendable {
    let annotationID: UUID
    let placement: ReaderNotePlacement
}

struct ReaderLocator: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let publicationFingerprint: String
    let resourceID: String
    let position: Int
    let progression: Double
    let textAnchor: TextAnchor?
    let rectangles: [ReaderRect]

    init(
        schemaVersion: Int = 1,
        publicationFingerprint: String,
        resourceID: String,
        position: Int,
        progression: Double,
        textAnchor: TextAnchor? = nil,
        rectangles: [ReaderRect] = []
    ) {
        self.schemaVersion = schemaVersion
        self.publicationFingerprint = publicationFingerprint
        self.resourceID = resourceID
        self.position = position
        self.progression = min(max(progression, 0), 1)
        self.textAnchor = textAnchor
        self.rectangles = rectangles
    }
}

struct ReaderSelection: Codable, Hashable, Sendable {
    let locator: ReaderLocator
    let selectedText: String
}

struct ReaderSelectionContext: Codable, Hashable, Sendable {
    let before: String
    let after: String
}

enum ReaderHighlightColor: String, CaseIterable, Codable, Hashable, Sendable {
    case lemon
    case petal
    case ember
    case aqua
    case moss

    var displayName: String { rawValue }

    init?(persistedValue: String) {
        switch persistedValue {
        case "sun": self = .lemon
        case "rose": self = .petal
        case "tide": self = .aqua
        default:
            guard let color = Self(rawValue: persistedValue) else { return nil }
            self = color
        }
    }

    var red: Double {
        switch self {
        case .lemon: 244.0 / 255.0
        case .petal: 255.0 / 255.0
        case .ember: 255.0 / 255.0
        case .aqua: 76.0 / 255.0
        case .moss: 70.0 / 255.0
        }
    }

    var green: Double {
        switch self {
        case .lemon: 230.0 / 255.0
        case .petal: 143.0 / 255.0
        case .ember: 166.0 / 255.0
        case .aqua: 203.0 / 255.0
        case .moss: 212.0 / 255.0
        }
    }

    var blue: Double {
        switch self {
        case .lemon: 75.0 / 255.0
        case .petal: 149.0 / 255.0
        case .ember: 74.0 / 255.0
        case .aqua: 209.0 / 255.0
        case .moss: 155.0 / 255.0
        }
    }
}

struct ReaderAnnotation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let publicationFingerprint: String
    let locator: ReaderLocator
    let selectedText: String
    let note: String?
    let notePlacement: ReaderNotePlacement?
    let highlightColor: ReaderHighlightColor
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        publicationFingerprint: String,
        locator: ReaderLocator,
        selectedText: String,
        note: String? = nil,
        notePlacement: ReaderNotePlacement? = nil,
        highlightColor: ReaderHighlightColor = .lemon,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.publicationFingerprint = publicationFingerprint
        self.locator = locator
        self.selectedText = selectedText
        self.note = note
        self.notePlacement = notePlacement
        self.highlightColor = highlightColor
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

struct PublicationTextChunk: Hashable, Sendable {
    let resourceID: String
    let title: String?
    let text: String
    let ordinal: Int
}

struct ReaderSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let resourceID: String
    let fragment: String?
    let depth: Int

    init(
        id: String,
        title: String,
        resourceID: String,
        fragment: String? = nil,
        depth: Int = 0
    ) {
        self.id = id
        self.title = title
        self.resourceID = resourceID
        self.fragment = fragment
        self.depth = max(depth, 0)
    }
}

struct ReaderSearchResult: Identifiable, Hashable, Sendable {
    let id: UUID
    let locator: ReaderLocator
    let excerpt: String
    let resourceTitle: String?

    init(
        id: UUID = UUID(),
        locator: ReaderLocator,
        excerpt: String,
        resourceTitle: String?
    ) {
        self.id = id
        self.locator = locator
        self.excerpt = excerpt
        self.resourceTitle = resourceTitle
    }
}

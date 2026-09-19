import Foundation

struct Book: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let author: String
    var progress: Double
    let coverStyle: BookCoverStyle
    let formatLabel: String
    let readingLength: ReadingLength
    let sample: ReadingSample
    let publication: PublicationReference?

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        progress: Double,
        coverStyle: BookCoverStyle,
        formatLabel: String,
        readingLength: ReadingLength,
        sample: ReadingSample,
        publication: PublicationReference? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.progress = min(max(progress, 0), 1)
        self.coverStyle = coverStyle
        self.formatLabel = formatLabel
        self.readingLength = readingLength
        self.sample = sample
        self.publication = publication
    }

    var libraryMetadataLabel: String {
        "\(readingLength.displayLabel) · \(formatLabel)"
    }

    var totalPageCount: Int? {
        switch readingLength {
        case .pages(let count), .estimatedPages(let count):
            count
        case .reflowable:
            nil
        }
    }

    var pagesRemainingLabel: String {
        if progress >= 0.995 { return "finished" }
        guard let totalPageCount else { return "pages" }
        if progress <= 0 {
            return "\(totalPageCount) \(totalPageCount == 1 ? "page" : "pages")"
        }
        let remaining = max(Int(ceil(Double(totalPageCount) * (1 - progress))), 1)
        return "\(remaining) \(remaining == 1 ? "page" : "pages") left"
    }
}

enum BookCoverStyle: String, Hashable, Sendable {
    case forest
    case night
    case parchment
    case clay
    case sea
}

enum ReadingLength: Hashable, Sendable {
    case pages(Int)
    case estimatedPages(Int)
    case reflowable

    var displayLabel: String {
        switch self {
        case .pages(let count):
            "\(count) \(count == 1 ? "page" : "pages")"
        case .estimatedPages(let count):
            "≈ \(count) \(count == 1 ? "page" : "pages")"
        case .reflowable:
            "Reflowable"
        }
    }
}

struct ReadingSample: Hashable, Sendable {
    let chapter: String
    let section: String
    let paragraphs: [String]
}

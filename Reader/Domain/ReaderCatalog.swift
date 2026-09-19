import Foundation

enum ReaderCatalogAvailability: String, Codable, Hashable, Sendable {
    case readNow = "read_now"
    case inLibrary = "in_library"
    case addOwnFile = "add_own_file"
    case notifyMe = "notify_me"

    var actionLabel: String {
        switch self {
        case .readNow: "read now"
        case .inLibrary: "open"
        case .addOwnFile: "add your file"
        case .notifyMe: "notify me"
        }
    }
}

enum ReaderCatalogSource: String, Codable, Hashable, Sendable {
    case readerCatalog = "reader_catalog"
    case googleBooks = "google_books"
}

struct ReaderCatalogResult: Identifiable, Codable, Hashable, Sendable {
    let source: ReaderCatalogSource?
    let externalId: String?
    let workGroupId: Int64?
    let workId: Int64?
    let editionId: Int64?
    let title: String
    let subtitle: String?
    let authors: String
    let translators: String
    let publisher: String?
    let releaseYear: Int?
    let pageCount: Int?
    let description: String?
    let coverUrl: URL?
    let primaryIdentifier: String?
    let availability: ReaderCatalogAvailability
    let libraryPublicationId: UUID?
    let downloadUrl: URL?
    let downloadMediaType: String?

    var id: String {
        let catalogSource = source ?? .readerCatalog
        if let workGroupId {
            return "\(catalogSource.rawValue):\(workGroupId)"
        }
        return "\(catalogSource.rawValue):\(externalId ?? primaryIdentifier ?? title)"
    }

    var isCanonical: Bool {
        (source ?? .readerCatalog) == .readerCatalog && workGroupId != nil
    }
    var byline: String { authors.isEmpty ? "unknown author" : authors }

    var metadataLine: String {
        [
            publisher,
            releaseYear.map(String.init),
            pageCount.map { "\($0) pages" },
            source == .googleBooks ? "Google Books" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

enum ReaderCatalogMatchSource: String, Codable, Sendable {
    case catalogOffer = "catalog_offer"
    case userFile = "user_file"
}

import Foundation
import Observation

enum QuietReaderScreen: String, Codable, Sendable {
    case launch
    case library
    case reading
    case ask
    case type
    case kept
    case ai
    case search
    case account
}

enum QuietLibraryFilter: String, CaseIterable, Codable, Sendable {
    case everything
    case reading
    case papers
    case finished

    var menuItem: QuietReaderMenuItem {
        switch self {
        case .everything: .everything
        case .reading: .reading
        case .papers: .papers
        case .finished: .finished
        }
    }
}

struct QuietReadingPreferences: Codable, Equatable, Sendable {
    var size: Int = 20
    var serif = false
    var theme = QuietReadingTheme.white

    mutating func changeSize(by delta: Int) {
        size = min(max(size + delta, 15), 30)
    }
}

@MainActor
@Observable
final class QuietReaderState {
    var screen: QuietReaderScreen
    var previousScreen: QuietReaderScreen = .library
    var filter: QuietLibraryFilter {
        didSet { persist() }
    }
    var preferences: QuietReadingPreferences {
        didSet { persist() }
    }
    var searchQuery = ""
    var pendingSearchFocus = false

    private let defaults: UserDefaults
    private let storageKey = "quiet-reader-state-v1"

    init(defaults: UserDefaults = .standard, hasResumeBook: Bool = false) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: storageKey),
            let persisted = try? JSONDecoder().decode(Persisted.self, from: data)
        {
            filter = persisted.filter
            preferences = persisted.preferences
        } else {
            filter = .everything
            preferences = QuietReadingPreferences()
        }
        screen = hasResumeBook ? .launch : .library
    }

    func show(_ destination: QuietReaderScreen) {
        guard destination != screen else { return }
        previousScreen = screen
        screen = destination
        if destination == .search {
            pendingSearchFocus = true
        }
    }

    func showLibrary(_ filter: QuietLibraryFilter) {
        self.filter = filter
        show(.library)
    }

    func escape() {
        switch screen {
        case .search:
            screen = previousScreen
        case .account, .kept, .ai:
            screen = .library
        default:
            break
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(
            Persisted(filter: filter, preferences: preferences)
        ) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private struct Persisted: Codable {
        let filter: QuietLibraryFilter
        let preferences: QuietReadingPreferences
    }
}

struct QuietResumeSnapshot: Sendable {
    let book: Book
    let sentence: String
    let openedAt: Date
}

struct QuietHighlightItem: Identifiable, Sendable {
    let annotation: ReaderAnnotation
    let book: Book

    var id: UUID { annotation.id }
}

struct ReaderConversation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let publicationID: UUID?
    let publicationTitle: String
    let question: String
    let answer: String
    let locator: ReaderLocator?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        publicationID: UUID?,
        publicationTitle: String,
        question: String,
        answer: String,
        locator: ReaderLocator?,
        createdAt: Date = .now
    ) {
        self.id = id
        self.publicationID = publicationID
        self.publicationTitle = publicationTitle
        self.question = question
        self.answer = answer
        self.locator = locator
        self.createdAt = createdAt
    }
}

enum QuietSearchSource: Hashable, Sendable {
    case publication(bookID: UUID, locator: ReaderLocator)
    case highlight(bookID: UUID, locator: ReaderLocator)
    case conversation(UUID)
}

struct QuietSearchResult: Identifiable, Hashable, Sendable {
    let id: UUID
    let text: String
    let sourceLine: String
    let coverStyle: BookCoverStyle?
    let source: QuietSearchSource
}

import Foundation
import Observation

enum WorkspacePaneID: String, CaseIterable, Codable, Hashable, Sendable {
    case main
    case bottom
    case right
}

enum WorkspaceTabKind: Codable, Hashable, Sendable {
    case book(UUID)
    case browser
    case chat
    case dictionary
}

struct WorkspaceTab: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: WorkspaceTabKind
    var title: String

    init(id: UUID = UUID(), kind: WorkspaceTabKind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }

    var systemImage: String {
        switch kind {
        case .book:
            "book.closed"
        case .browser:
            "globe"
        case .chat:
            "message"
        case .dictionary:
            "book"
        }
    }
}

struct WorkspacePaneState: Codable, Sendable {
    var tabs: [WorkspaceTab]
    var selectedTabID: UUID?

    init(tabs: [WorkspaceTab] = []) {
        self.tabs = tabs
        self.selectedTabID = tabs.first?.id
    }
}

@MainActor
@Observable
final class WorkspaceModel {
    var main = WorkspacePaneState() { didSet { persist() } }
    var bottom = WorkspacePaneState() { didSet { persist() } }
    var right = WorkspacePaneState() { didSet { persist() } }
    var isBottomVisible = false { didSet { persist() } }
    var isRightVisible = false { didSet { persist() } }
    var rightPaneWidth: CGFloat = 390 { didSet { persist() } }
    var bottomPaneHeight: CGFloat = 300 { didSet { persist() } }
    var pendingImportPane: WorkspacePaneID = .main
    private(set) var browserSessions: [UUID: BrowserSession] = [:]
    private(set) var assistantSessions: [UUID: ReaderAssistantSession] = [:]
    private(set) var dictionarySessions: [UUID: ReaderDictionarySession] = [:]
    @ObservationIgnored var onConversationCompleted: ((ReaderConversation) -> Void)? {
        didSet {
            assistantSessions.values.forEach {
                $0.onConversationCompleted = onConversationCompleted
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let persistenceKey: String

    init(
        defaults: UserDefaults? = nil,
        persistenceKey: String = "reader-workspace-state-v1"
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey

        guard
            let data = defaults?.data(forKey: persistenceKey),
            let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
            snapshot.schemaVersion == WorkspaceSnapshot.currentSchemaVersion
        else { return }

        main = snapshot.main
        bottom = snapshot.bottom
        right = snapshot.right
        isBottomVisible = snapshot.isBottomVisible
        isRightVisible = snapshot.isRightVisible
        rightPaneWidth = min(640, max(280, CGFloat(snapshot.rightPaneWidth)))
        bottomPaneHeight = max(
            WorkspacePaneSizing.minimumBottomPaneHeight,
            CGFloat(snapshot.bottomPaneHeight)
        )
        browserSessions = Dictionary(
            uniqueKeysWithValues: snapshot.browsers.map { saved in
                (saved.tabID, BrowserSession(snapshot: saved.session))
            }
        )
        assistantSessions = Dictionary(
            uniqueKeysWithValues: snapshot.assistants.map { saved in
                (saved.tabID, ReaderAssistantSession(snapshot: saved.session))
            }
        )
        dictionarySessions = Dictionary(
            uniqueKeysWithValues: (snapshot.dictionaries ?? []).map { saved in
                (saved.tabID, ReaderDictionarySession(snapshot: saved.session))
            }
        )
        attachSessionPersistence()
    }

    static func live() -> WorkspaceModel {
        WorkspaceModel(defaults: .standard)
    }

    func pane(_ id: WorkspacePaneID) -> WorkspacePaneState {
        switch id {
        case .main: main
        case .bottom: bottom
        case .right: right
        }
    }

    func browserSession(for tabID: UUID) -> BrowserSession {
        if let existing = browserSessions[tabID] {
            return existing
        }
        let session = BrowserSession()
        attachPersistence(to: session)
        browserSessions[tabID] = session
        persist()
        return session
    }

    func assistantSession(for tabID: UUID) -> ReaderAssistantSession {
        if let existing = assistantSessions[tabID] {
            return existing
        }
        let session = ReaderAssistantSession()
        session.onConversationCompleted = onConversationCompleted
        attachPersistence(to: session, tabID: tabID)
        assistantSessions[tabID] = session
        persist()
        return session
    }

    func dictionarySession(for tabID: UUID) -> ReaderDictionarySession {
        if let existing = dictionarySessions[tabID] {
            return existing
        }
        let session = ReaderDictionarySession()
        attachPersistence(to: session)
        dictionarySessions[tabID] = session
        persist()
        return session
    }

    func select(_ tabID: UUID, in paneID: WorkspacePaneID) {
        mutatePane(paneID) { pane in
            guard pane.tabs.contains(where: { $0.id == tabID }) else { return }
            pane.selectedTabID = tabID
        }
    }

    func rename(_ tabID: UUID, to title: String) {
        guard !title.isEmpty else { return }
        for paneID in WorkspacePaneID.allCases {
            mutatePane(paneID) { pane in
                guard let index = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                pane.tabs[index].title = title
            }
        }
    }

    func activateBook(_ book: Book) {
        openBook(book, in: .main)
    }

    func openBook(_ book: Book, in paneID: WorkspacePaneID) {
        if let existing = pane(paneID).tabs.first(where: { $0.kind == .book(book.id) }) {
            select(existing.id, in: paneID)
        } else {
            add(WorkspaceTab(kind: .book(book.id), title: book.title), to: paneID)
        }
    }

    @discardableResult
    func openBrowser(in paneID: WorkspacePaneID) -> UUID {
        let tab = WorkspaceTab(kind: .browser, title: "Google")
        let session = BrowserSession()
        attachPersistence(to: session)
        browserSessions[tab.id] = session
        add(tab, to: paneID)
        return tab.id
    }

    func openChat(in paneID: WorkspacePaneID) {
        let tab = WorkspaceTab(kind: .chat, title: "chat")
        let session = ReaderAssistantSession()
        session.onConversationCompleted = onConversationCompleted
        attachPersistence(to: session, tabID: tab.id)
        assistantSessions[tab.id] = session
        add(tab, to: paneID)
    }

    @discardableResult
    func openDictionary(in paneID: WorkspacePaneID) -> UUID {
        let tab = WorkspaceTab(kind: .dictionary, title: "Dictionary")
        let session = ReaderDictionarySession()
        attachPersistence(to: session)
        dictionarySessions[tab.id] = session
        add(tab, to: paneID)
        return tab.id
    }

    @discardableResult
    func openDictionary(
        for term: ReaderDictionaryTerm,
        in paneID: WorkspacePaneID = .right
    ) -> UUID {
        if let reusableTab = pane(paneID).tabs.last(where: { tab in
            tab.kind == .dictionary
                && dictionarySessions[tab.id]?.canReceiveSelectionLookup == true
        }) {
            let session = dictionarySession(for: reusableTab.id)
            session.showSelectionLookup(term)
            rename(reusableTab.id, to: "Dictionary · \(term.value)")
            select(reusableTab.id, in: paneID)
            if paneID == .bottom { isBottomVisible = true }
            if paneID == .right { isRightVisible = true }
            return reusableTab.id
        }

        let tab = WorkspaceTab(
            kind: .dictionary,
            title: "Dictionary · \(term.value)"
        )
        let session = ReaderDictionarySession(
            searchText: term.value,
            preservesManualLookup: false
        )
        attachPersistence(to: session)
        dictionarySessions[tab.id] = session
        add(tab, to: paneID)
        return tab.id
    }

    @discardableResult
    func openHighlightQuestion(
        _ source: HighlightQuestionDraft,
        in paneID: WorkspacePaneID = .right
    ) -> UUID {
        let paneState = pane(paneID)
        if let selectedTabID = paneState.selectedTabID,
           paneState.tabs.first(where: { $0.id == selectedTabID })?.kind == .chat,
           let session = assistantSessions[selectedTabID],
           session.canReceiveSelection {
            session.attachSelection(source)
            select(selectedTabID, in: paneID)
            if paneID == .bottom { isBottomVisible = true }
            if paneID == .right { isRightVisible = true }
            return selectedTabID
        }

        let tab = WorkspaceTab(kind: .chat, title: "chat")
        let session = ReaderAssistantSession(source: source)
        session.onConversationCompleted = onConversationCompleted
        attachPersistence(to: session, tabID: tab.id)
        assistantSessions[tab.id] = session
        add(tab, to: paneID)
        return tab.id
    }

    @discardableResult
    func attachSelectionToVisibleAssistant(
        _ source: HighlightQuestionDraft
    ) -> Bool {
        for paneID in [WorkspacePaneID.right, .bottom] {
            let isVisible = switch paneID {
            case .right: isRightVisible
            case .bottom: isBottomVisible
            case .main: true
            }
            guard isVisible else { continue }
            let paneState = pane(paneID)
            guard
                let selectedTabID = paneState.selectedTabID,
                paneState.tabs.first(where: { $0.id == selectedTabID })?.kind == .chat,
                let session = assistantSessions[selectedTabID],
                session.canReceiveSelection
            else { continue }
            session.attachSelection(source)
            return true
        }
        return false
    }

    func close(_ tabID: UUID, in paneID: WorkspacePaneID) {
        mutatePane(paneID) { pane in
            guard let index = pane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let wasSelected = pane.selectedTabID == tabID
            pane.tabs.remove(at: index)

            if wasSelected {
                pane.selectedTabID = pane.tabs.isEmpty
                    ? nil
                    : pane.tabs[min(index, pane.tabs.count - 1)].id
            }
        }
        browserSessions[tabID] = nil
        assistantSessions[tabID] = nil
        dictionarySessions[tabID] = nil
        normalizeAfterRemoval(from: paneID)
        persist()
    }

    func move(_ tabID: UUID, to destination: WorkspacePaneID) {
        guard let source = WorkspacePaneID.allCases.first(where: {
            pane($0).tabs.contains(where: { $0.id == tabID })
        }) else { return }

        guard source != destination else {
            select(tabID, in: destination)
            return
        }

        guard let tab = pane(source).tabs.first(where: { $0.id == tabID }) else { return }
        mutatePane(source) { pane in
            pane.tabs.removeAll { $0.id == tabID }
            if pane.selectedTabID == tabID {
                pane.selectedTabID = pane.tabs.first?.id
            }
        }
        add(tab, to: destination)
        normalizeAfterRemoval(from: source)
    }

    func toggleBottom() {
        isBottomVisible.toggle()
    }

    func toggleRight() {
        isRightVisible.toggle()
    }

    func reset() {
        main = WorkspacePaneState()
        bottom = WorkspacePaneState()
        right = WorkspacePaneState()
        isBottomVisible = false
        isRightVisible = false
        pendingImportPane = .main
        browserSessions.removeAll()
        assistantSessions.removeAll()
        dictionarySessions.removeAll()
        persist()
    }

    func reconcileBooks(validBookIDs: Set<UUID>) {
        for paneID in WorkspacePaneID.allCases {
            mutatePane(paneID) { pane in
                pane.tabs.removeAll { tab in
                    if case .book(let id) = tab.kind {
                        return !validBookIDs.contains(id)
                    }
                    return false
                }
                if let selected = pane.selectedTabID,
                   !pane.tabs.contains(where: { $0.id == selected }) {
                    pane.selectedTabID = pane.tabs.first?.id
                }
            }
        }
        persist()
    }

    private func add(_ tab: WorkspaceTab, to paneID: WorkspacePaneID) {
        mutatePane(paneID) { pane in
            pane.tabs.append(tab)
            pane.selectedTabID = tab.id
        }

        if paneID == .bottom { isBottomVisible = true }
        if paneID == .right { isRightVisible = true }
    }

    private func normalizeAfterRemoval(from paneID: WorkspacePaneID) {
        guard pane(paneID).tabs.isEmpty else { return }

        switch paneID {
        case .main:
            break
        case .bottom:
            isBottomVisible = false
        case .right:
            isRightVisible = false
        }
    }

    private func mutatePane(
        _ id: WorkspacePaneID,
        mutation: (inout WorkspacePaneState) -> Void
    ) {
        switch id {
        case .main:
            mutation(&main)
        case .bottom:
            mutation(&bottom)
        case .right:
            mutation(&right)
        }
    }

    private func attachSessionPersistence() {
        browserSessions.values.forEach(attachPersistence)
        assistantSessions.forEach { tabID, session in
            attachPersistence(to: session, tabID: tabID)
        }
        dictionarySessions.values.forEach(attachPersistence)
    }

    private func attachPersistence(to session: BrowserSession) {
        session.onStateChanged = { [weak self] in self?.persist() }
    }

    private func attachPersistence(
        to session: ReaderAssistantSession,
        tabID: UUID
    ) {
        session.onStateChanged = { [weak self] in self?.persist() }
        session.onTitleChanged = { [weak self] title in
            self?.rename(tabID, to: title)
        }
    }

    private func attachPersistence(to session: ReaderDictionarySession) {
        session.onStateChanged = { [weak self] in self?.persist() }
    }

    private func persist() {
        guard let defaults else { return }
        let snapshot = WorkspaceSnapshot(
            main: main,
            bottom: bottom,
            right: right,
            isBottomVisible: isBottomVisible,
            isRightVisible: isRightVisible,
            rightPaneWidth: Double(rightPaneWidth),
            bottomPaneHeight: Double(bottomPaneHeight),
            browsers: browserSessions.map { tabID, session in
                SavedBrowserSession(tabID: tabID, session: session.snapshot)
            },
            assistants: assistantSessions.map { tabID, session in
                SavedAssistantSession(tabID: tabID, session: session.snapshot)
            },
            dictionaries: dictionarySessions.map { tabID, session in
                SavedDictionarySession(tabID: tabID, session: session.snapshot)
            }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: persistenceKey)
    }
}

private struct WorkspaceSnapshot: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let main: WorkspacePaneState
    let bottom: WorkspacePaneState
    let right: WorkspacePaneState
    let isBottomVisible: Bool
    let isRightVisible: Bool
    let rightPaneWidth: Double
    let bottomPaneHeight: Double
    let browsers: [SavedBrowserSession]
    let assistants: [SavedAssistantSession]
    let dictionaries: [SavedDictionarySession]?

    init(
        main: WorkspacePaneState,
        bottom: WorkspacePaneState,
        right: WorkspacePaneState,
        isBottomVisible: Bool,
        isRightVisible: Bool,
        rightPaneWidth: Double,
        bottomPaneHeight: Double,
        browsers: [SavedBrowserSession],
        assistants: [SavedAssistantSession],
        dictionaries: [SavedDictionarySession]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.main = main
        self.bottom = bottom
        self.right = right
        self.isBottomVisible = isBottomVisible
        self.isRightVisible = isRightVisible
        self.rightPaneWidth = rightPaneWidth
        self.bottomPaneHeight = bottomPaneHeight
        self.browsers = browsers
        self.assistants = assistants
        self.dictionaries = dictionaries
    }
}

private struct SavedBrowserSession: Codable {
    let tabID: UUID
    let session: BrowserSessionSnapshot
}

private struct SavedAssistantSession: Codable {
    let tabID: UUID
    let session: ReaderAssistantSessionSnapshot
}

private struct SavedDictionarySession: Codable {
    let tabID: UUID
    let session: ReaderDictionarySessionSnapshot
}

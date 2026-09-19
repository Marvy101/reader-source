import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var model: LibraryModel
    @Bindable var account: ReaderAccountModel

    @State private var workspace: WorkspaceModel
    @State private var quietState: QuietReaderState
    @State private var toast = QuietToastCenter()
    @State private var searchResults: [QuietSearchResult] = []
    @State private var catalogResults: [ReaderCatalogResult] = []
    @State private var isCatalogLoading = false
    @State private var pendingCatalogMatch: ReaderCatalogResult?
    @State private var bookPickerLibrary: ReaderLibraryOption?
    @State private var activeConversation: ReaderConversation?
    private let catalogDemoMode: Bool

    init(
        model: LibraryModel,
        account: ReaderAccountModel,
        catalogDemoMode: Bool = false
    ) {
        self.model = model
        self.account = account
        self.catalogDemoMode = catalogDemoMode
        let restoredWorkspace = WorkspaceModel.live()
        restoredWorkspace.reconcileBooks(validBookIDs: Set(model.books.map(\.id)))
        _workspace = State(initialValue: restoredWorkspace)
        _quietState = State(
            initialValue: QuietReaderState(
                hasResumeBook: model.hasResumeBook
            )
        )
    }

    var body: some View {
        Group {
            if account.isAuthenticated {
                authenticatedContent
                    .transition(.opacity)
            } else {
                ReaderAuthenticationView(account: account)
                    .transition(.opacity)
            }
        }
        .background(QuietReaderColor.paper)
        .animation(QuietReaderMotion.screen, value: account.isAuthenticated)
        .animation(QuietReaderMotion.screen, value: quietState.screen)
        .overlay { QuietToastOverlay(center: toast) }
        .onChange(of: model.showImporter) { _, isPresented in
            guard isPresented else { return }
            model.showImporter = false
            Task { @MainActor in
                if let result = await PublicationFilePicker.selectFiles() {
                    let catalogMatch = pendingCatalogMatch
                    pendingCatalogMatch = nil
                    importFiles(
                        result,
                        catalogMatch: catalogMatch,
                        matchSource: catalogMatch == nil ? nil : .userFile
                    )
                }
            }
        }
        .focusedSceneValue(
            \.quietReaderActions,
            QuietReaderActions(
                importFiles: { model.showImporter = true },
                search: { quietState.show(.search) },
                library: closeWorkspace,
                type: { quietState.show(.type) },
                openBrowserRight: { openUtility(.browser, in: .right) },
                openBrowserBottom: { openUtility(.browser, in: .bottom) },
                openAIRight: { openUtility(.chat, in: .right) },
                openAIBottom: { openUtility(.chat, in: .bottom) },
                toggleRightPane: workspace.toggleRight,
                toggleBottomPane: workspace.toggleBottom
            )
        )
        .onChange(of: account.isAuthenticated) { _, authenticated in
            if authenticated {
                quietState.screen = model.hasResumeBook ? .launch : .library
                reconcileCloudLibrary()
            } else {
                workspace.reset()
                model.closeReader()
                model.resetCloudSyncStatus()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            reconcileCloudLibrary()
        }
        .onAppear {
            model.onBookImported = { book in
                synchronizeBookWithCloud(book)
            }
            model.onBookKnowledgeAvailable = { snapshot in
                if let book = model.books.first(where: {
                    $0.id == snapshot.publicationID
                }) {
                    synchronizeBookWithCloud(book, snapshot: snapshot)
                }
            }
            workspace.onConversationCompleted = { conversation in
                model.recordConversation(conversation)
            }
            reconcileCloudLibrary()
        }
        .task(id: quietState.searchQuery) {
            guard quietState.screen == .search else { return }
            let query = quietState.searchQuery
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                searchResults = []
                catalogResults = []
                isCatalogLoading = false
                return
            }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            searchResults = model.searchAll(query)
            if catalogDemoMode {
                catalogResults = Self.catalogDemoResults
                return
            }
            guard query.count >= 2 else {
                catalogResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled else { return }
            isCatalogLoading = true
            defer { isCatalogLoading = false }
            do {
                catalogResults = try await account.searchCatalog(
                    query,
                    locale: catalogLocale
                )
            } catch is CancellationError {
                return
            } catch {
                catalogResults = []
            }
        }
        .task(id: account.session?.user.id) {
            guard account.isAuthenticated else { return }
            await model.reconcileCloudLibrary(using: account)
            await model.synchronizeReadingStates(using: account)
            await model.synchronizeAnnotations(using: account)
        }
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        switch quietState.screen {
        case .launch:
            if let snapshot = model.resumeSnapshot() {
                QuietLaunchView(
                    snapshot: snapshot,
                    goOn: { openBook(snapshot.book) },
                    openLibrary: closeWorkspace
                )
            } else {
                collectionShell(selection: quietState.filter.menuItem) {
                    libraryScreen
                }
            }

        case .library:
            collectionShell(selection: quietState.filter.menuItem) {
                libraryScreen
            }

        case .kept:
            collectionShell(selection: .kept) {
                QuietKeptScreen(items: model.highlights) { item in
                    openBook(item.book, at: item.annotation.locator)
                }
            }

        case .ai:
            collectionShell(selection: .ai) {
                QuietAIListScreen(conversations: model.conversations) { conversation in
                    openConversation(conversation)
                }
            }

        case .search:
            collectionShell(selection: .search) {
                QuietSearchScreen(
                    query: $quietState.searchQuery,
                    results: searchResults,
                    catalogResults: catalogResults,
                    isCatalogLoading: isCatalogLoading,
                    open: openSearchResult,
                    catalogAction: performCatalogAction,
                    escape: quietState.escape
                )
            }

        case .account:
            QuietAccountScreen(
                account: account,
                books: model.books,
                syncMessage: model.cloudSyncMessage,
                openLibrary: closeWorkspace,
                openType: { quietState.show(.type) },
                signOut: {
                    workspace.reset()
                    model.closeReader()
                    account.signOut()
                }
            )

        case .type:
            QuietTypeScreen(
                preferences: $quietState.preferences,
                back: returnFromType
            )

        case .reading:
            if let book = model.openBook {
                WorkspaceView(
                    rootBookID: book.id,
                    library: model,
                    workspace: workspace,
                    account: account,
                    preferences: quietState.preferences,
                    openType: { quietState.show(.type) },
                    closeWorkspace: closeWorkspace
                )
            } else {
                collectionShell(selection: quietState.filter.menuItem) {
                    libraryScreen
                }
            }

        case .ask:
            if let activeConversation {
                QuietAskScreen(
                    conversation: activeConversation,
                    backToPage: { returnToConversationSource(activeConversation) },
                    otherReadings: { quietState.show(.ai) },
                    lookUp: { lookUp(activeConversation) }
                )
            } else {
                collectionShell(selection: .ai) {
                    QuietAIListScreen(conversations: model.conversations) { conversation in
                        openConversation(conversation)
                    }
                }
            }
        }
    }

    private var libraryScreen: some View {
        QuietLibraryScreen(
            allBooks: model.books,
            bookPickerLibrary: $bookPickerLibrary,
            addBookToLibrary: { book, libraryID in
                try await model.move(book, to: libraryID, using: account)
            },
            books: model.books(
                for: quietState.filter,
                in: model.selectedLibraryID
            ),
            isLibraryEmpty: model.books.isEmpty,
            libraries: model.libraryOptions,
            selectedLibraryID: model.selectedLibraryID,
            openBook: openBook,
            search: { quietState.show(.search) },
            importBooks: { model.showImporter = true },
            importDroppedBooks: { urls in
                importFiles(.success(urls))
                return true
            },
            selectLibrary: { libraryID in
                model.selectedLibraryID = libraryID
            },
            browseAllBooks: {
                model.selectedLibraryID = nil
                quietState.showLibrary(.everything)
            },
            createLibrary: createLibrary,
            renameLibrary: renameLibrary,
            deleteLibrary: deleteLibrary,
            libraryIDForBook: model.libraryID(for:),
            moveBook: moveBook,
            reorderBook: { model.reorder($0, to: $1) },
            persistBookOrder: persistBookOrder
        )
    }

    private func createLibrary(_ name: String) {
        Task { @MainActor in
            do {
                let library = try await model.createLibrary(
                    named: name,
                    using: account
                )
                model.selectedLibraryID = library.id
                quietState.showLibrary(.everything)
                bookPickerLibrary = model.libraryOptions.first { $0.id == library.id }
                toast.show("made \(library.name.lowercased())", kind: .done)
            } catch {
                toast.show(error.localizedDescription.lowercased(), kind: .stop)
            }
        }
    }

    private func moveBook(_ book: Book, to libraryID: UUID?) {
        Task { @MainActor in
            do {
                try await model.move(book, to: libraryID, using: account)
                let destination = model.libraryOptions.first {
                    $0.id == libraryID
                }?.title ?? "no library"
                toast.show("moved to \(destination.lowercased())", kind: .done)
            } catch {
                toast.show(error.localizedDescription.lowercased(), kind: .stop)
            }
        }
    }

    private func renameLibrary(_ libraryID: UUID, to name: String) {
        Task { @MainActor in
            do {
                let library = try await model.renameLibrary(
                    libraryID,
                    to: name,
                    using: account
                )
                toast.show("renamed to \(library.name.lowercased())", kind: .done)
            } catch {
                toast.show(error.localizedDescription.lowercased(), kind: .stop)
            }
        }
    }

    private func deleteLibrary(_ libraryID: UUID) {
        Task { @MainActor in
            do {
                try await model.deleteLibrary(libraryID, using: account)
                toast.show("library deleted", kind: .done)
            } catch {
                toast.show(error.localizedDescription.lowercased(), kind: .stop)
            }
        }
    }

    private func persistBookOrder() {
        Task { @MainActor in
            do {
                try await model.persistBookOrder(using: account)
            } catch {
                toast.show("saved here, but cloud order will retry", kind: .note)
            }
        }
    }

    private func collectionShell<Content: View>(
        selection: QuietReaderMenuItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            content()
            QuietReaderMenuColumn(
                selection: selection,
                mark: account.accountMark,
                select: selectMenu,
                openAccount: { quietState.show(.account) }
            )
        }
    }

    private func selectMenu(_ item: QuietReaderMenuItem) {
        switch item {
        case .search:
            quietState.show(.search)
        case .everything:
            quietState.showLibrary(.everything)
        case .reading:
            quietState.showLibrary(.reading)
        case .papers:
            quietState.showLibrary(.papers)
        case .finished:
            quietState.showLibrary(.finished)
        case .kept:
            quietState.show(.kept)
        case .ai:
            quietState.show(.ai)
        }
    }

    private func openBook(_ book: Book) {
        model.open(book)
        workspace.activateBook(book)
        quietState.show(.reading)
        synchronizeBookWithCloud(book)
    }

    private func reconcileCloudLibrary() {
        guard account.isAuthenticated else { return }
        Task { @MainActor in
            await model.reconcileCloudLibrary(using: account)
        }
    }

    private func synchronizeBookWithCloud(
        _ book: Book,
        snapshot preparedSnapshot: ReaderBookKnowledgeSnapshot? = nil
    ) {
        guard account.isAuthenticated else { return }
        Task { @MainActor in
            await model.synchronizeBookWithCloud(
                book,
                snapshot: preparedSnapshot,
                using: account
            )
            model.scheduleReadingStateSynchronization(using: account)
        }
    }

    private func openBook(_ book: Book, at locator: ReaderLocator) {
        model.open(book, at: locator)
        workspace.activateBook(book)
        quietState.show(.reading)
        synchronizeBookWithCloud(book)
    }

    private func closeWorkspace() {
        model.closeReader()
        quietState.show(.library)
    }

    private func returnFromType() {
        if model.openBook != nil {
            quietState.show(.reading)
        } else {
            quietState.show(.library)
        }
    }

    private func openUtility(_ utility: WorkspaceTabKind, in pane: WorkspacePaneID) {
        guard let current = model.openBook ?? model.currentBook ?? model.books.first else {
            toast.show("add a book first", kind: .note)
            return
        }
        if model.openBook == nil {
            model.open(current)
            workspace.activateBook(current)
        }
        switch utility {
        case .browser:
            workspace.openBrowser(in: pane)
        case .chat:
            workspace.openChat(in: pane)
        case .dictionary:
            workspace.openDictionary(in: pane)
        case .book:
            break
        }
        quietState.show(.reading)
    }

    private func openSearchResult(_ result: QuietSearchResult) {
        switch result.source {
        case .publication(let bookID, let locator), .highlight(let bookID, let locator):
            guard let book = model.books.first(where: { $0.id == bookID }) else { return }
            openBook(book, at: locator)
        case .conversation(let id):
            guard let conversation = model.conversations.first(where: { $0.id == id }) else {
                return
            }
            openConversation(conversation)
        }
    }

    private func openConversation(_ conversation: ReaderConversation) {
        activeConversation = conversation
        quietState.show(.ask)
    }

    private func returnToConversationSource(_ conversation: ReaderConversation) {
        if
            let bookID = conversation.publicationID,
            let locator = conversation.locator,
            let book = model.books.first(where: { $0.id == bookID })
        {
            openBook(book, at: locator)
        } else {
            quietState.show(.ai)
        }
    }

    private func lookUp(_ conversation: ReaderConversation) {
        guard let current = model.openBook ?? model.currentBook ?? model.books.first else {
            toast.show("add a book first", kind: .note)
            return
        }
        if model.openBook == nil {
            model.open(current)
            workspace.activateBook(current)
        }
        let tabID = workspace.openBrowser(in: .right)
        let session = workspace.browserSession(for: tabID)
        session.addressText = conversation.question
        session.navigateFromAddressBar()
        quietState.show(.reading)
    }

    private func importFiles(
        _ result: Result<[URL], Error>,
        catalogMatch: ReaderCatalogResult? = nil,
        matchSource: ReaderCatalogMatchSource? = nil
    ) {
        switch result {
        case .success(let urls):
            let destination = workspace.pendingImportPane
            let previousRootBook = model.openBook
            let imported = model.importFiles(urls)
            guard !imported.isEmpty else {
                if let message = model.importErrorMessage {
                    toast.show(message, kind: .stop)
                    model.importErrorMessage = nil
                } else {
                    toast.show("already in your library", kind: .note)
                }
                return
            }

            if destination == .main {
                openBook(imported[0])
                for book in imported.dropFirst() {
                    workspace.openBook(book, in: .main)
                }
            } else {
                if let previousRootBook { model.open(previousRootBook) }
                for book in imported {
                    workspace.openBook(book, in: destination)
                }
                quietState.show(.reading)
            }
            workspace.pendingImportPane = .main
            toast.show(
                imported.count == 1 ? "sent to your library" : "sent to your library",
                kind: .done
            )
            Task { await model.synchronizeAnnotations(using: account) }
            if
                let catalogMatch,
                let matchSource,
                let matchedBook = imported.first
            {
                Task { @MainActor in
                    do {
                        try await account.syncOriginalFile(for: matchedBook)
                        try await account.matchLibraryFile(
                            matchedBook.id,
                            to: catalogMatch,
                            source: matchSource
                        )
                        catalogResults = catalogResults.map { result in
                            guard result.id == catalogMatch.id else { return result }
                            return ReaderCatalogResult(
                                source: result.source,
                                externalId: result.externalId,
                                workGroupId: result.workGroupId,
                                workId: result.workId,
                                editionId: result.editionId,
                                title: result.title,
                                subtitle: result.subtitle,
                                authors: result.authors,
                                translators: result.translators,
                                publisher: result.publisher,
                                releaseYear: result.releaseYear,
                                pageCount: result.pageCount,
                                description: result.description,
                                coverUrl: result.coverUrl,
                                primaryIdentifier: result.primaryIdentifier,
                                availability: .inLibrary,
                                libraryPublicationId: matchedBook.id,
                                downloadUrl: result.downloadUrl,
                                downloadMediaType: result.downloadMediaType
                            )
                        }
                    } catch {
                        toast.show("saved locally; catalog match failed", kind: .note)
                    }
                }
            }

        case .failure(let error):
            toast.show(error.localizedDescription, kind: .stop)
        }
    }

    private var catalogLocale: String {
        Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    private func performCatalogAction(_ result: ReaderCatalogResult) {
        switch result.availability {
        case .readNow:
            downloadCatalogBook(result)
        case .inLibrary:
            openCatalogLibraryBook(result)
        case .addOwnFile:
            pendingCatalogMatch = result.isCanonical ? result : nil
            model.showImporter = true
        case .notifyMe:
            if catalogDemoMode {
                toast.show("we'll let you know", kind: .done)
                return
            }
            Task { @MainActor in
                do {
                    try await account.registerCatalogInterest(
                        result,
                        emailOptIn: true
                    )
                    toast.show("we'll let you know", kind: .done)
                } catch {
                    toast.show(error.localizedDescription.lowercased(), kind: .stop)
                }
            }
        }
    }

    private static let catalogDemoResults = [
        ReaderCatalogResult(
            source: .googleBooks,
            externalId: "demo-half-of-a-yellow-sun",
            workGroupId: nil,
            workId: nil,
            editionId: nil,
            title: "Half of a Yellow Sun",
            subtitle: nil,
            authors: "Chimamanda Ngozi Adichie",
            translators: "",
            publisher: "Anchor",
            releaseYear: 2006,
            pageCount: 560,
            description: nil,
            coverUrl: URL(string: "https://covers.openlibrary.org/b/isbn/9780007200283-M.jpg"),
            primaryIdentifier: "isbn:9780007200283",
            availability: .notifyMe,
            libraryPublicationId: nil,
            downloadUrl: nil,
            downloadMediaType: nil
        ),
        ReaderCatalogResult(
            source: .googleBooks,
            externalId: "demo-americanah",
            workGroupId: nil,
            workId: nil,
            editionId: nil,
            title: "Americanah",
            subtitle: nil,
            authors: "Chimamanda Ngozi Adichie",
            translators: "",
            publisher: "Knopf",
            releaseYear: 2013,
            pageCount: 496,
            description: nil,
            coverUrl: URL(string: "https://covers.openlibrary.org/b/isbn/9780307271082-M.jpg"),
            primaryIdentifier: "isbn:9780307271082",
            availability: .notifyMe,
            libraryPublicationId: nil,
            downloadUrl: nil,
            downloadMediaType: nil
        ),
        ReaderCatalogResult(
            source: .googleBooks,
            externalId: "demo-we-should-all-be-feminists",
            workGroupId: nil,
            workId: nil,
            editionId: nil,
            title: "We Should All Be Feminists",
            subtitle: nil,
            authors: "Chimamanda Ngozi Adichie",
            translators: "",
            publisher: "Vintage",
            releaseYear: 2014,
            pageCount: 64,
            description: nil,
            coverUrl: URL(string: "https://covers.openlibrary.org/b/isbn/9781101911761-M.jpg"),
            primaryIdentifier: "isbn:9781101911761",
            availability: .notifyMe,
            libraryPublicationId: nil,
            downloadUrl: nil,
            downloadMediaType: nil
        ),
    ]

    private func openCatalogLibraryBook(_ result: ReaderCatalogResult) {
        guard let publicationID = result.libraryPublicationId else { return }
        if let book = model.books.first(where: { $0.id == publicationID }) {
            openBook(book)
            return
        }
        Task { @MainActor in
            await model.synchronizeLibraries(using: account)
            if let book = model.books.first(where: { $0.id == publicationID }) {
                openBook(book)
            } else {
                toast.show("that book is still restoring", kind: .note)
            }
        }
    }

    private func downloadCatalogBook(_ result: ReaderCatalogResult) {
        guard let downloadURL = result.downloadUrl else { return }
        Task { @MainActor in
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(
                    from: downloadURL
                )
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard
                    let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode)
                else {
                    throw ReaderBackendError.invalidResponse
                }

                let stagingDirectory = FileManager.default.temporaryDirectory
                    .appending(path: "ReaderCatalogDownloads", directoryHint: .isDirectory)
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                    at: stagingDirectory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: stagingDirectory) }
                let fileStem = result.workGroupId.map(String.init) ?? UUID().uuidString
                let stagedURL = stagingDirectory.appending(
                    path: "\(fileStem).\(catalogFileExtension(for: result))"
                )
                try FileManager.default.copyItem(at: temporaryURL, to: stagedURL)
                let canonicalMatch = result.isCanonical ? result : nil
                importFiles(
                    .success([stagedURL]),
                    catalogMatch: canonicalMatch,
                    matchSource: canonicalMatch == nil ? nil : .catalogOffer
                )
            } catch {
                toast.show("couldn't download that book", kind: .stop)
            }
        }
    }

    private func catalogFileExtension(for result: ReaderCatalogResult) -> String {
        switch result.downloadMediaType?.lowercased() {
        case "application/epub+zip": "epub"
        case "application/pdf": "pdf"
        case "text/plain": "txt"
        default: "epub"
        }
    }
}

import XCTest
@testable import Reader

@MainActor
final class WorkspaceModelTests: XCTestCase {
    func testBottomAndRightPanesOpenWithChooserInsteadOfImplicitContent() {
        let model = WorkspaceModel()

        model.toggleBottom()
        model.toggleRight()

        XCTAssertTrue(model.isBottomVisible)
        XCTAssertTrue(model.isRightVisible)
        XCTAssertTrue(model.bottom.tabs.isEmpty)
        XCTAssertTrue(model.right.tabs.isEmpty)
    }

    func testBottomPaneCanReachHalfOfTallWorkspace() {
        XCTAssertEqual(
            WorkspacePaneSizing.maximumBottomPaneHeight(for: 1_200),
            600
        )
        XCTAssertEqual(
            WorkspacePaneSizing.clampedBottomPaneHeight(800, workspaceHeight: 1_200),
            600
        )
    }

    func testBottomPaneMinimumWinsWhenWorkspaceIsShort() {
        XCTAssertEqual(
            WorkspacePaneSizing.maximumBottomPaneHeight(for: 400),
            WorkspacePaneSizing.minimumBottomPaneHeight
        )
        XCTAssertEqual(
            WorkspacePaneSizing.clampedBottomPaneHeight(100, workspaceHeight: 400),
            WorkspacePaneSizing.minimumBottomPaneHeight
        )
    }

    func testClosingLastTabAutomaticallyClosesAuxiliaryPane() {
        let model = WorkspaceModel()
        let bottomTabID = model.openBrowser(in: .bottom)
        let rightTabID = model.openBrowser(in: .right)

        model.close(bottomTabID, in: .bottom)
        model.close(rightTabID, in: .right)

        XCTAssertTrue(model.bottom.tabs.isEmpty)
        XCTAssertFalse(model.isBottomVisible)
        XCTAssertTrue(model.right.tabs.isEmpty)
        XCTAssertFalse(model.isRightVisible)
    }

    func testClosingTabKeepsAuxiliaryPaneOpenWhileAnotherTabRemains() {
        let model = WorkspaceModel()
        let firstTabID = model.openBrowser(in: .right)
        model.openChat(in: .right)

        model.close(firstTabID, in: .right)

        XCTAssertEqual(model.right.tabs.count, 1)
        XCTAssertTrue(model.isRightVisible)
    }

    func testTabCanMoveBetweenAllPanes() throws {
        let model = WorkspaceModel()
        model.openBrowser(in: .main)
        let browser = try XCTUnwrap(model.main.tabs.last)

        model.move(browser.id, to: .bottom)
        XCTAssertTrue(model.isBottomVisible)
        XCTAssertEqual(model.bottom.selectedTabID, browser.id)
        XCTAssertFalse(model.main.tabs.contains(where: { $0.id == browser.id }))

        model.move(browser.id, to: .right)
        XCTAssertTrue(model.isRightVisible)
        XCTAssertEqual(model.right.selectedTabID, browser.id)
        XCTAssertFalse(model.bottom.tabs.contains(where: { $0.id == browser.id }))
    }

    func testBookWorkspaceDoesNotCreateALibraryTab() throws {
        let model = WorkspaceModel()
        let book = makeBook()

        model.activateBook(book)

        XCTAssertEqual(model.main.tabs.count, 1)
        XCTAssertEqual(model.main.tabs.first?.kind, .book(book.id))
        XCTAssertFalse(model.main.tabs.contains { tab in
            if case .book = tab.kind { return false }
            return true
        })
    }

    func testBrowserSessionFollowsItsTabWhenMoved() throws {
        let model = WorkspaceModel()
        model.openBrowser(in: .main)
        let browser = try XCTUnwrap(model.main.tabs.last)
        let session = model.browserSession(for: browser.id)
        session.addressText = "example.com"

        model.move(browser.id, to: .right)

        XCTAssertTrue(model.browserSession(for: browser.id) === session)
        XCTAssertEqual(model.browserSession(for: browser.id).addressText, "example.com")
    }

    func testHighlightQuestionOpensAContextualAssistantInRightPane() throws {
        let model = WorkspaceModel()
        let source = makeHighlightQuestionDraft()

        model.openHighlightQuestion(source)

        XCTAssertTrue(model.isRightVisible)
        let tab = try XCTUnwrap(model.right.tabs.first)
        XCTAssertEqual(tab.kind, .chat)
        XCTAssertEqual(model.assistantSession(for: tab.id).source, source)
    }

    func testHighlightQuestionUpdatesTheSelectedChatInsteadOfOpeningAnother() throws {
        let model = WorkspaceModel()
        model.openChat(in: .right)
        let chatID = try XCTUnwrap(model.right.selectedTabID)
        let source = makeHighlightQuestionDraft()

        let updatedTabID = model.openHighlightQuestion(source)

        XCTAssertEqual(updatedTabID, chatID)
        XCTAssertEqual(model.right.tabs.count, 1)
        XCTAssertEqual(model.right.selectedTabID, chatID)
        let session = model.assistantSession(for: chatID)
        XCTAssertEqual(session.source, source)
        XCTAssertEqual(session.effectiveContextScope, .passage)
    }

    func testSelectionAutomaticallyUpdatesAVisibleAssistant() throws {
        let model = WorkspaceModel()
        model.openChat(in: .right)
        let chatID = try XCTUnwrap(model.right.selectedTabID)
        let source = makeHighlightQuestionDraft()

        let didAttach = model.attachSelectionToVisibleAssistant(source)

        XCTAssertTrue(didAttach)
        XCTAssertEqual(model.right.tabs.count, 1)
        XCTAssertEqual(model.assistantSession(for: chatID).source, source)
        XCTAssertEqual(
            model.assistantSession(for: chatID).effectiveContextScope,
            .passage
        )
    }

    func testSelectionDoesNotOpenOrUpdateAHiddenAssistant() throws {
        let model = WorkspaceModel()
        model.openChat(in: .right)
        let chatID = try XCTUnwrap(model.right.selectedTabID)
        model.toggleRight()

        let didAttach = model.attachSelectionToVisibleAssistant(
            makeHighlightQuestionDraft()
        )

        XCTAssertFalse(didAttach)
        XCTAssertNil(model.assistantSession(for: chatID).source)
        XCTAssertFalse(model.isRightVisible)
    }

    func testSelectionLookupsReuseTheUneditedDictionaryTab() throws {
        let model = WorkspaceModel()
        let first = try XCTUnwrap(ReaderDictionaryTerm("serendipity"))
        let second = try XCTUnwrap(ReaderDictionaryTerm("ephemeral"))

        let firstTabID = model.openDictionary(for: first)
        let secondTabID = model.openDictionary(for: second)

        XCTAssertEqual(secondTabID, firstTabID)
        XCTAssertEqual(model.right.tabs.count, 1)
        XCTAssertEqual(model.right.selectedTabID, firstTabID)
        XCTAssertEqual(model.dictionarySession(for: firstTabID).searchText, "ephemeral")
        XCTAssertTrue(model.dictionarySession(for: firstTabID).canReceiveSelectionLookup)
    }

    func testRedundantDictionaryTextUpdatePreservesTheResolvedLookup() {
        let session = ReaderDictionarySession(
            searchText: "serendipity",
            preservesManualLookup: false
        )
        let originalEntry = session.entry
        var stateChangeCount = 0
        session.onStateChanged = { stateChangeCount += 1 }

        session.updateSearchTextFromUser("serendipity")

        XCTAssertEqual(session.searchText, "serendipity")
        XCTAssertEqual(session.entry, originalEntry)
        XCTAssertTrue(session.lookupWasAttempted)
        XCTAssertTrue(session.canReceiveSelectionLookup)
        XCTAssertEqual(stateChangeCount, 0)
    }

    func testManualDictionaryEditProtectsTheTabFromTheNextSelectionLookup() throws {
        let model = WorkspaceModel()
        let first = try XCTUnwrap(ReaderDictionaryTerm("serendipity"))
        let second = try XCTUnwrap(ReaderDictionaryTerm("ephemeral"))
        let firstTabID = model.openDictionary(for: first)
        let firstSession = model.dictionarySession(for: firstTabID)

        firstSession.updateSearchTextFromUser("sagacity")
        firstSession.submitManualLookup()
        let secondTabID = model.openDictionary(for: second)

        XCTAssertNotEqual(secondTabID, firstTabID)
        XCTAssertEqual(model.right.tabs.count, 2)
        XCTAssertEqual(firstSession.searchText, "sagacity")
        XCTAssertFalse(firstSession.canReceiveSelectionLookup)
        XCTAssertEqual(model.dictionarySession(for: secondTabID).searchText, "ephemeral")
    }

    func testDictionaryOpenedFromPaneChooserIsManualAndNotReused() throws {
        let model = WorkspaceModel()
        let manualTabID = model.openDictionary(in: .bottom)
        let term = try XCTUnwrap(ReaderDictionaryTerm("serendipity"))

        let selectionTabID = model.openDictionary(for: term, in: .bottom)

        XCTAssertNotEqual(selectionTabID, manualTabID)
        XCTAssertEqual(model.bottom.tabs.map(\.kind), [.dictionary, .dictionary])
        XCTAssertFalse(model.dictionarySession(for: manualTabID).canReceiveSelectionLookup)
    }

    func testWorkspaceRestoresTabsPaneStateSizesAndSessionContext() throws {
        let suite = "WorkspaceModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "workspace"
        let book = makeBook()
        let model = WorkspaceModel(defaults: defaults, persistenceKey: key)

        model.activateBook(book)
        let browserID = model.openBrowser(in: .right)
        let browser = model.browserSession(for: browserID)
        let exampleURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        browser.didUpdate(
            url: exampleURL,
            title: "Example article",
            canGoBack: true,
            canGoForward: false,
            isLoading: false
        )
        model.rename(browserID, to: "Example article")

        let source = makeHighlightQuestionDraft()
        model.openHighlightQuestion(source, in: .bottom)
        let chat = try XCTUnwrap(model.bottom.tabs.last)
        model.assistantSession(for: chat.id).draftQuestion = "What does this mean?"
        let dictionaryTerm = try XCTUnwrap(ReaderDictionaryTerm("serendipity"))
        let dictionaryID = model.openDictionary(for: dictionaryTerm, in: .right)
        model.dictionarySession(for: dictionaryID).updateSearchTextFromUser("sagacity")
        model.rightPaneWidth = 432
        model.bottomPaneHeight = 640

        let restored = WorkspaceModel(defaults: defaults, persistenceKey: key)

        XCTAssertEqual(restored.main.tabs.map(\.kind), [.book(book.id)])
        XCTAssertEqual(restored.right.tabs.map(\.id), [browserID, dictionaryID])
        XCTAssertEqual(restored.right.selectedTabID, dictionaryID)
        XCTAssertEqual(restored.browserSession(for: browserID).currentURL, exampleURL)
        XCTAssertEqual(restored.browserSession(for: browserID).title, "Example article")
        XCTAssertEqual(restored.dictionarySession(for: dictionaryID).searchText, "sagacity")
        XCTAssertFalse(restored.dictionarySession(for: dictionaryID).canReceiveSelectionLookup)
        XCTAssertEqual(restored.bottom.tabs.map(\.id), [chat.id])
        XCTAssertEqual(restored.assistantSession(for: chat.id).source, source)
        XCTAssertEqual(
            restored.assistantSession(for: chat.id).draftQuestion,
            "What does this mean?"
        )
        XCTAssertTrue(restored.isRightVisible)
        XCTAssertTrue(restored.isBottomVisible)
        XCTAssertEqual(restored.rightPaneWidth, 432)
        XCTAssertEqual(restored.bottomPaneHeight, 640)
    }

    func testActivatingAnotherBookPreservesExistingWorkspaceTabs() {
        let model = WorkspaceModel()
        model.openBrowser(in: .right)
        let firstBook = makeBook()
        let secondBook = Book(
            title: "Second Book",
            author: "Test Author",
            progress: 0,
            coverStyle: .forest,
            formatLabel: "TXT",
            readingLength: .reflowable,
            sample: ReadingSample(chapter: "", section: "", paragraphs: [])
        )

        model.activateBook(firstBook)
        model.activateBook(secondBook)

        XCTAssertEqual(model.main.tabs.count, 2)
        XCTAssertEqual(model.main.selectedTabID, model.main.tabs.last?.id)
        XCTAssertEqual(model.right.tabs.count, 1)
    }

    func testReconcileRemovesOnlyUnavailableBookTabs() {
        let model = WorkspaceModel()
        let book = makeBook()
        model.activateBook(book)
        model.openBrowser(in: .right)

        model.reconcileBooks(validBookIDs: [])

        XCTAssertTrue(model.main.tabs.isEmpty)
        XCTAssertEqual(model.right.tabs.map(\.kind), [.browser])
    }

    private func makeBook() -> Book {
        Book(
            title: "Test Book",
            author: "Test Author",
            progress: 0,
            coverStyle: .night,
            formatLabel: "TXT",
            readingLength: .reflowable,
            sample: ReadingSample(chapter: "", section: "", paragraphs: [])
        )
    }

    private func makeHighlightQuestionDraft() -> HighlightQuestionDraft {
        HighlightQuestionDraft(
            publicationTitle: "Test Book",
            publicationAuthor: "Test Author",
            publicationFormat: .plainText,
            selection: ReaderSelection(
                locator: ReaderLocator(
                    publicationFingerprint: "fingerprint",
                    resourceID: "text",
                    position: 0,
                    progression: 0
                ),
                selectedText: "Selected text"
            ),
            context: ReaderSelectionContext(before: "Before", after: "After")
        )
    }
}

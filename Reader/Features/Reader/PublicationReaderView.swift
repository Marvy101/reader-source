import SwiftUI

struct ReaderSelectionAutomaticLookupGate {
    private let stabilizationInterval: TimeInterval
    private var initialSelection: ReaderSelection?
    private var firstObservedAt: TimeInterval?
    private var suppressesCurrentInteraction = false
    private var emittedLookup = false

    init(stabilizationInterval: TimeInterval = 0.35) {
        self.stabilizationInterval = stabilizationInterval
    }

    mutating func observe(
        _ selection: ReaderSelection?,
        at timestamp: TimeInterval
    ) -> ReaderDictionaryTerm? {
        guard let selection else {
            reset()
            return nil
        }

        if let initialSelection, initialSelection != selection {
            suppressesCurrentInteraction = true
            return nil
        }

        if initialSelection == nil {
            initialSelection = selection
            firstObservedAt = timestamp
            if ReaderDictionaryTerm(selection.selectedText)?.isSingleWord != true {
                suppressesCurrentInteraction = true
            }
            return nil
        }

        guard
            !suppressesCurrentInteraction,
            !emittedLookup,
            let firstObservedAt,
            timestamp - firstObservedAt >= stabilizationInterval,
            let term = ReaderDictionaryTerm(selection.selectedText),
            term.isSingleWord
        else { return nil }

        emittedLookup = true
        return term
    }

    private mutating func reset() {
        initialSelection = nil
        firstObservedAt = nil
        suppressesCurrentInteraction = false
        emittedLookup = false
    }
}

private struct ActiveReaderInlineRewrite: Equatable {
    let selection: ReaderSelection
    let source: HighlightQuestionDraft
    var currentDraft: String?
    var lastCommand: ReaderRewriteCommand
    var requestID: UUID
}

struct PublicationReaderContainerView: View {
    let book: Book
    @Bindable var library: LibraryModel
    @Bindable var account: ReaderAccountModel
    let preferences: QuietReadingPreferences
    let askSelection: (HighlightQuestionDraft) -> Void
    let selectionChanged: (HighlightQuestionDraft) -> Void
    let rewriteSelection: (HighlightQuestionDraft, ReaderRewriteCommand) async throws -> String
    let defineSelection: (String) -> Void
    let openType: () -> Void
    let close: () -> Void

    @State private var session: PublicationReaderSession?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let session {
                PublicationReaderView(
                    session: session,
                    preferences: preferences,
                    askSelection: askSelection,
                    selectionChanged: selectionChanged,
                    rewriteSelection: rewriteSelection,
                    defineSelection: defineSelection,
                    openType: openType,
                    close: close
                )
            } else if let loadError {
                VStack(spacing: 24) {
                    QuietVoiceText(
                        text: loadError,
                        size: 15,
                        color: QuietToastKind.stop.dotColor
                    )
                    QuietActionWord(title: "library", action: close)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QuietVoiceText(
                    text: "preparing \(book.title)",
                    size: 15,
                    color: QuietReaderColor.voice
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: book.id) {
            do {
                session = try library.makeReaderSession(
                    for: book,
                    annotationChanged: { _ in
                        Task { await library.synchronizeAnnotations(using: account) }
                    },
                    readingStateChanged: {
                        library.scheduleReadingStateSynchronization(using: account)
                    }
                )
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct PublicationReaderView: View {
    @Bindable var session: PublicationReaderSession
    let preferences: QuietReadingPreferences
    let askSelection: (HighlightQuestionDraft) -> Void
    let selectionChanged: (HighlightQuestionDraft) -> Void
    let rewriteSelection: (HighlightQuestionDraft, ReaderRewriteCommand) async throws -> String
    let defineSelection: (String) -> Void
    let openType: () -> Void
    let close: () -> Void

    @State private var showSearch = false
    @State private var showContents = false
    @State private var currentSelection: ReaderSelection?
    @State private var handledSelection: ReaderSelection?
    @State private var selectionAnchor: ReaderViewportPoint?
    @State private var selectionMode = ReaderSelectionPanelMode.actions
    @State private var rewriteState = ReaderSelectionRewriteState.idle
    @State private var activeInlineRewrite: ActiveReaderInlineRewrite?
    @State private var noteDraft = ""
    @State private var automaticLookupGate = ReaderSelectionAutomaticLookupGate()
    @State private var selectionHandoffTask: Task<Void, Never>?
    @State private var activeHighlightID: UUID?
    @State private var noteEditorIsOpen = false
    @FocusState private var searchIsFocused: Bool
    @AppStorage("reader.default-highlight-color") private var defaultHighlightColorRaw = ReaderHighlightColor.lemon.rawValue

    private var defaultHighlightColor: ReaderHighlightColor {
        ReaderHighlightColor(persistedValue: defaultHighlightColorRaw) ?? .lemon
    }

    private var currentHighlightColor: ReaderHighlightColor {
        guard let activeHighlightID else { return defaultHighlightColor }
        return session.annotations.first(where: { $0.id == activeHighlightID })?.highlightColor
            ?? defaultHighlightColor
    }

    private var progress: Double {
        if session.adapter.resourceCount <= 1 {
            return session.book.progress
        }
        return min(
            max(Double(session.resourceIndex) / Double(session.adapter.resourceCount - 1), 0),
            1
        )
    }

    private var chapterLabel: String {
        if let selected = session.sections.first(where: { $0.id == session.selectedSectionID }) {
            return selected.title
        }
        if session.usesDiscretePageControls {
            return "page \(session.resourceIndex + 1)"
        }
        return session.sections.first?.title ?? session.book.title
    }

    private var pageLabel: String {
        if let total = session.book.totalPageCount {
            let page = min(max(Int(progress * Double(total)) + 1, 1), total)
            return "\(page) of \(total)"
        }
        return "\(Int(progress * 100))%"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                preferences.theme.background.ignoresSafeArea()
                surface

                if showContents {
                    contentsPanel
                        .frame(width: min(300, geometry.size.width * 0.32))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .transition(.opacity)
                }

                readingChrome(width: geometry.size.width)

                if let selection = currentSelection {
                    selectionActions(
                        selection,
                        maximumWidth: max(280, min(430, geometry.size.width - 32))
                    )
                        .position(selectionPanelPosition(in: geometry.size))
                        .transition(.opacity)
                }

                if showSearch {
                    searchPanel
                        .padding(.top, 18)
                        .padding(.trailing, 22)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(20)
                }
            }
        }
        .animation(QuietReaderMotion.screen, value: showSearch)
        .animation(QuietReaderMotion.screen, value: showContents)
        .animation(QuietReaderMotion.screen, value: currentSelection?.selectedText)
        .onExitCommand {
            if activeInlineRewrite != nil {
                dismissInlineRewrite()
            } else if currentSelection != nil {
                dismissSelection()
            } else if showSearch || showContents {
                dismissSearch()
                showContents = false
            } else {
                close()
            }
        }
        .focusedSceneValue(
            \.readerZoomActions,
            ReaderZoomActions(
                zoomIn: { session.changeTextScale(by: 0.1) },
                zoomOut: { session.changeTextScale(by: -0.1) },
                actualSize: { session.resetTextScale() }
            )
        )
        .focusedSceneValue(
            \.readerReadingActions,
            ReaderReadingActions(
                contents: { showContents.toggle() },
                find: presentSearch,
                keep: keepSelection,
                note: beginNote,
                ask: askAboutSelection,
                previousPage: { session.moveResource(by: -1) },
                nextPage: { session.moveResource(by: 1) }
            )
        )
        .onAppear {
            session.applyAppearance(preferences)
            session.adapter.onAnnotationNoteRequested = { request in
                presentAnnotationNote(request)
            }
            session.adapter.onAnnotationNotePlacementChanged = { request in
                session.updateNotePlacement(
                    id: request.annotationID,
                    placement: request.placement
                )
            }
        }
        .onChange(of: preferences) { _, updated in
            session.applyAppearance(updated)
        }
        .task {
            var tick = 0
            while !Task.isCancelled {
                if let action = await session.captureInlineRewriteAction() {
                    handleInlineRewriteAction(action)
                }
                let capturedSelection = await session.captureSelection()
                let automaticLookup = automaticLookupGate.observe(
                    capturedSelection,
                    at: ProcessInfo.processInfo.systemUptime
                )
                if let selection = capturedSelection {
                    selectionAnchor = session.adapter.selectionViewportAnchor
                    if selection != currentSelection, selection != handledSelection {
                        presentSelection(selection)
                    }
                } else if capturedSelection == nil, !noteEditorIsOpen {
                    currentSelection = nil
                    handledSelection = nil
                    selectionAnchor = nil
                }
                if let automaticLookup {
                    defineSelection(automaticLookup.value)
                }
                tick += 1
                if tick.isMultiple(of: 8) {
                    await session.persistReadingState()
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .onDisappear {
            session.dismissInlineRewrite()
            session.adapter.onAnnotationNoteRequested = nil
            session.adapter.onAnnotationNotePlacementChanged = nil
            Task { await session.persistReadingState() }
        }
    }

    @ViewBuilder
    private var surface: some View {
        switch session.backend {
        case .pdf(let adapter):
            PDFKitSurfaceView(adapter: adapter)
        case .web(let adapter):
            WebKitSurfaceView(adapter: adapter)
        }
    }

    private func readingChrome(width: CGFloat) -> some View {
        ZStack {
            QuietVoiceText(
                text: chapterLabel,
                color: preferences.theme.ink.opacity(0.46)
            )
            .lineLimit(1)
            .padding(.leading, 48)
            .padding(.top, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Button(action: close) {
                QuietVoiceText(
                    text: "library",
                    color: preferences.theme.ink.opacity(0.46)
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, 48)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            HStack(spacing: 22) {
                Button(action: openType) {
                    QuietVoiceText(
                        text: "type",
                        color: preferences.theme.ink.opacity(0.46)
                    )
                }
                .buttonStyle(.plain)
                QuietVoiceText(
                    text: pageLabel,
                    color: preferences.theme.ink.opacity(0.46)
                )
            }
            .padding(.trailing, 48)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            Rectangle()
                .fill(preferences.theme.ink.opacity(0.28))
                .frame(width: max(width * progress, 1), height: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(true)
    }

    private func selectionActions(
        _ selection: ReaderSelection,
        maximumWidth: CGFloat
    ) -> some View {
        let availability = ReaderSelectionActionAvailability(
            selectedText: selection.selectedText
        )

        return ReaderSelectionPanel(
            selection: selection,
            canDefine: availability.canDefine,
            canRewriteWithAI: availability.canRewriteWithAI,
            theme: preferences.theme,
            mode: selectionMode,
            rewriteState: rewriteState,
            highlightColor: currentHighlightColor,
            noteDraft: $noteDraft,
            highlight: highlightSelection,
            showHighlightColors: showHighlightColors,
            chooseHighlightColor: chooseHighlightColor,
            showDefinition: showDefinition,
            keep: keepSelection,
            beginNote: beginNote,
            copy: copySelection,
            ask: askAboutSelection,
            rewriteWithAI: rewriteSelectionText,
            saveNote: { saveNote(selection) }
        )
        .frame(
            width: selectionMode == .note || selectionMode == .rewrite
                ? maximumWidth
                : nil
        )
    }

    private var searchPanel: some View {
        HStack(spacing: 10) {
            TextField("find in book", text: $session.searchQuery)
                .textFieldStyle(.plain)
                .font(QuietReaderTypography.appVoice(size: 13))
                .foregroundStyle(preferences.theme.ink)
                .focused($searchIsFocused)
                .frame(minWidth: 150)
                .onSubmit { session.moveSearchResult(by: 1) }
                .onChange(of: session.searchQuery) { _, _ in
                    session.scheduleSearch()
                }

            QuietVoiceText(
                text: session.searchResultLabel,
                size: 11,
                color: preferences.theme.ink.opacity(0.48)
            )
            .lineLimit(1)
            .frame(minWidth: 56, alignment: .trailing)

            findButton(systemName: "chevron.up") {
                session.moveSearchResult(by: -1)
            }
            .disabled(session.searchResults.isEmpty)
            .accessibilityLabel("Previous match")

            findButton(systemName: "chevron.down") {
                session.moveSearchResult(by: 1)
            }
            .disabled(session.searchResults.isEmpty)
            .accessibilityLabel("Next match")

            findButton(systemName: "xmark", action: dismissSearch)
                .accessibilityLabel("Close find in book")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(width: 352)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(preferences.theme.background.opacity(0.97))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(preferences.theme.ink.opacity(0.09), lineWidth: 1)
        }
    }

    private func findButton(
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(preferences.theme.ink.opacity(0.62))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var contentsPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                ForEach(session.sections) { section in
                    Button {
                        session.navigate(to: section)
                        showContents = false
                    } label: {
                        Text(section.title)
                            .font(QuietReaderTypography.appVoice(size: 13))
                            .foregroundStyle(
                                session.selectedSectionID == section.id
                                    ? preferences.theme.ink
                                    : preferences.theme.ink.opacity(0.46)
                            )
                            .multilineTextAlignment(.leading)
                            .padding(.leading, CGFloat(min(section.depth, 4)) * 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 48)
            .padding(.top, 88)
            .padding(.bottom, 80)
        }
        .scrollIndicators(.never)
        .background(preferences.theme.background.opacity(0.98))
    }

    private func keepSelection() {
        guard let currentSelection else { return }
        session.createHighlight(
            currentSelection,
            color: currentHighlightColor
        )
        dismissSelection()
    }

    private func highlightSelection() {
        guard let currentSelection else { return }
        session.createHighlight(
            currentSelection,
            color: defaultHighlightColor
        )
        dismissSelection()
    }

    private func showHighlightColors() {
        guard currentSelection != nil else { return }
        selectionMode = selectionMode == .colors ? .actions : .colors
    }

    private func chooseHighlightColor(_ color: ReaderHighlightColor) {
        guard let currentSelection else { return }
        defaultHighlightColorRaw = color.rawValue
        if let activeHighlightID {
            session.updateHighlightColor(id: activeHighlightID, color: color)
        } else {
            session.createHighlight(
                currentSelection,
                color: color
            )
        }
        dismissSelection()
    }

    private func beginNote() {
        guard currentSelection != nil else { return }
        noteEditorIsOpen = true
        if let activeHighlightID {
            noteDraft = session.annotations.first {
                $0.id == activeHighlightID
            }?.note ?? ""
        }
        selectionMode = .note
    }

    private func saveNote(_ selection: ReaderSelection) {
        if let activeHighlightID {
            session.updateNote(id: activeHighlightID, note: noteDraft)
        } else {
            guard !noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            session.createHighlight(
                selection,
                note: noteDraft,
                color: currentHighlightColor
            )
        }
        dismissSelection()
    }

    private func presentSearch() {
        showContents = false
        showSearch = true
        if !session.searchQuery.isEmpty {
            session.search()
        }
        Task { @MainActor in
            searchIsFocused = true
        }
    }

    private func dismissSearch() {
        showSearch = false
        searchIsFocused = false
        session.clearSearch()
    }

    private func askAboutSelection() {
        guard currentSelection != nil else { return }
        Task {
            if let source = await session.captureHighlightQuestion() {
                askSelection(source)
                dismissSelection()
            }
        }
    }

    private func rewriteSelectionText() {
        guard let selection = currentSelection else { return }
        if session.supportsInlineRewrite {
            Task {
                guard let source = await session.captureHighlightQuestion() else {
                    guard currentSelection == selection else { return }
                    selectionMode = .rewrite
                    rewriteState = .failed("could not capture this passage")
                    return
                }
                guard await session.beginInlineRewrite(selection) else {
                    guard currentSelection == selection else { return }
                    selectionMode = .rewrite
                    rewriteState = .loading
                    do {
                        let rewrittenText = try await rewriteSelection(
                            source,
                            ReaderRewriteCommand()
                        )
                        guard currentSelection == selection else { return }
                        rewriteState = .result(rewrittenText)
                    } catch {
                        guard currentSelection == selection else { return }
                        rewriteState = .failed(error.localizedDescription)
                    }
                    return
                }

                handledSelection = selection
                currentSelection = nil
                selectionAnchor = nil
                selectionMode = .actions
                rewriteState = .idle
                let command = ReaderRewriteCommand()
                let requestID = UUID()
                activeInlineRewrite = ActiveReaderInlineRewrite(
                    selection: selection,
                    source: source,
                    currentDraft: nil,
                    lastCommand: command,
                    requestID: requestID
                )
                await requestInlineRewrite(
                    source: source,
                    command: command,
                    requestID: requestID
                )
            }
            return
        }

        selectionMode = .rewrite
        rewriteState = .loading

        Task {
            guard let source = await session.captureHighlightQuestion() else {
                guard currentSelection == selection else { return }
                rewriteState = .failed("could not capture this passage")
                return
            }

            do {
                let rewrittenText = try await rewriteSelection(
                    source,
                    ReaderRewriteCommand()
                )
                guard currentSelection == selection else { return }
                rewriteState = .result(rewrittenText)
            } catch {
                guard currentSelection == selection else { return }
                rewriteState = .failed(error.localizedDescription)
            }
        }
    }

    private func presentSelection(_ selection: ReaderSelection) {
        if activeInlineRewrite != nil {
            dismissInlineRewrite()
        }
        noteEditorIsOpen = false
        currentSelection = selection
        selectionAnchor = session.adapter.selectionViewportAnchor
        noteDraft = ""
        selectionMode = .actions
        rewriteState = .idle
        activeHighlightID = session.annotations.first {
            $0.publicationFingerprint == session.adapter.fingerprint
                && $0.locator == selection.locator
                && $0.selectedText == selection.selectedText
        }?.id

        selectionHandoffTask?.cancel()
        selectionHandoffTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, currentSelection == selection else { return }
            guard let draft = session.highlightQuestionDraft(for: selection) else {
                return
            }
            selectionChanged(draft)
        }
    }

    private func presentAnnotationNote(_ request: ReaderAnnotationNoteRequest) {
        guard
            let annotation = session.annotations.first(where: {
                $0.id == request.annotationID
            }),
            annotation.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return }

        noteEditorIsOpen = true
        currentSelection = ReaderSelection(
            locator: annotation.locator,
            selectedText: annotation.selectedText
        )
        handledSelection = nil
        selectionAnchor = request.viewportPoint
        noteDraft = annotation.note ?? ""
        selectionMode = .note
        rewriteState = .idle
        activeHighlightID = annotation.id
    }

    private func showDefinition() {
        guard
            let currentSelection,
            let term = ReaderDictionaryTerm(currentSelection.selectedText)
        else { return }
        defineSelection(term.value)
        dismissSelection()
    }

    private func copySelection() {
        guard let currentSelection else { return }
        ReaderClipboard.copy(currentSelection.selectedText)
        dismissSelection()
    }

    private func selectionPanelPosition(in size: CGSize) -> CGPoint {
        let width = max(280, min(430, size.width - 32))
        let estimatedHeight: CGFloat = switch selectionMode {
        case .note: 116
        case .copied: 88
        case .actions: 54
        case .colors: 54
        case .rewrite: 230
        }
        let fallback = ReaderViewportPoint(
            x: size.width / 2,
            y: size.height * 0.44
        )
        let anchor = selectionAnchor ?? fallback
        let halfWidth = width / 2
        let halfHeight = estimatedHeight / 2
        let x = min(max(CGFloat(anchor.x), halfWidth + 12), size.width - halfWidth - 12)
        let above = CGFloat(anchor.y) - halfHeight - 18
        let y = above >= halfHeight + 12
            ? above
            : min(size.height - halfHeight - 12, CGFloat(anchor.y) + halfHeight + 28)
        return CGPoint(x: x, y: y)
    }

    private func dismissSelection() {
        selectionHandoffTask?.cancel()
        selectionHandoffTask = nil
        noteEditorIsOpen = false
        handledSelection = currentSelection
        session.adapter.clearSelection()
        currentSelection = nil
        selectionAnchor = nil
        selectionMode = .actions
        rewriteState = .idle
        noteDraft = ""
        activeHighlightID = nil
    }

    private func handleInlineRewriteAction(_ action: ReaderInlineRewriteAction) {
        switch action {
        case .dismiss:
            dismissInlineRewrite()
        case .retry:
            guard var activeInlineRewrite else { return }
            let requestID = UUID()
            activeInlineRewrite.requestID = requestID
            self.activeInlineRewrite = activeInlineRewrite
            session.restartInlineRewriteLoading()
            Task {
                await requestInlineRewrite(
                    source: activeInlineRewrite.source,
                    command: activeInlineRewrite.lastCommand,
                    requestID: requestID
                )
            }
        case .rewrite(let instruction):
            guard var activeInlineRewrite else { return }
            let command = ReaderRewriteCommand(
                instruction: instruction,
                currentDraft: activeInlineRewrite.currentDraft
            )
            guard command.instruction != nil else { return }
            let requestID = UUID()
            activeInlineRewrite.lastCommand = command
            activeInlineRewrite.requestID = requestID
            self.activeInlineRewrite = activeInlineRewrite
            session.restartInlineRewriteLoading()
            Task {
                await requestInlineRewrite(
                    source: activeInlineRewrite.source,
                    command: command,
                    requestID: requestID
                )
            }
        }
    }

    private func requestInlineRewrite(
        source: HighlightQuestionDraft,
        command: ReaderRewriteCommand,
        requestID: UUID
    ) async {
        do {
            let rewrittenText = try await rewriteSelection(source, command)
            guard var activeInlineRewrite, activeInlineRewrite.requestID == requestID else {
                return
            }
            activeInlineRewrite.currentDraft = rewrittenText
            self.activeInlineRewrite = activeInlineRewrite
            session.showInlineRewrite(rewrittenText)
        } catch {
            guard activeInlineRewrite?.requestID == requestID else { return }
            session.showInlineRewriteFailure(error.localizedDescription)
        }
    }

    private func dismissInlineRewrite() {
        session.dismissInlineRewrite()
        activeInlineRewrite = nil
    }
}

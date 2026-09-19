import SwiftUI

#if os(macOS)
import AppKit
#endif

enum WorkspacePaneSizing {
    static let minimumBottomPaneHeight: CGFloat = 220
    static let dividerHitArea: CGFloat = 24

    static func maximumBottomPaneHeight(for workspaceHeight: CGFloat) -> CGFloat {
        max(minimumBottomPaneHeight, workspaceHeight / 2)
    }

    static func clampedBottomPaneHeight(
        _ height: CGFloat,
        workspaceHeight: CGFloat
    ) -> CGFloat {
        min(
            maximumBottomPaneHeight(for: workspaceHeight),
            max(minimumBottomPaneHeight, height)
        )
    }
}

struct WorkspaceView: View {
    let rootBookID: UUID
    @Bindable var library: LibraryModel
    @Bindable var workspace: WorkspaceModel
    @Bindable var account: ReaderAccountModel
    let preferences: QuietReadingPreferences
    let openType: () -> Void
    let closeWorkspace: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedRightPaneWidth: CGFloat = 0
    @State private var presentedBottomPaneHeight: CGFloat = 0
    @State private var presentedRightPaneOpacity = 0.0
    @State private var presentedBottomPaneOpacity = 0.0
    @State private var rightResizeStart: CGFloat?
    @State private var bottomResizeStart: CGFloat?
    @State private var isRightResizing = false
    @State private var isBottomResizing = false

    var body: some View {
        GeometryReader { geometry in
            workspaceLayout(availableHeight: geometry.size.height)
        }
        .background(ReaderColors.canvas)
    }

    private func workspaceLayout(availableHeight: CGFloat) -> some View {
        let maximumBottomPaneHeight = WorkspacePaneSizing.maximumBottomPaneHeight(
            for: availableHeight
        )

        return HStack(spacing: 0) {
            centerStack(maximumBottomPaneHeight: maximumBottomPaneHeight)
                .frame(minWidth: 480)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            pane(.right)
                .frame(width: presentedRightPaneWidth)
                .opacity(presentedRightPaneOpacity)
                .clipped()
                .allowsHitTesting(workspace.isRightVisible)
                .accessibilityHidden(!workspace.isRightVisible)
        }
        .overlay {
            GeometryReader { geometry in
                rightDivider
                    .frame(height: geometry.size.height)
                    .position(
                        x: geometry.size.width - presentedRightPaneWidth,
                        y: geometry.size.height / 2
                    )
                    .allowsHitTesting(workspace.isRightVisible)
                    .accessibilityHidden(!workspace.isRightVisible)
            }
        }
        .onAppear {
            presentedRightPaneWidth = workspace.isRightVisible ? workspace.rightPaneWidth : 0
            presentedBottomPaneHeight = workspace.isBottomVisible
                ? min(workspace.bottomPaneHeight, maximumBottomPaneHeight)
                : 0
            presentedRightPaneOpacity = workspace.isRightVisible ? 1 : 0
            presentedBottomPaneOpacity = workspace.isBottomVisible ? 1 : 0
        }
        .onChange(of: workspace.isRightVisible) { _, isVisible in
            updatePanePresentation {
                presentedRightPaneWidth = isVisible ? workspace.rightPaneWidth : 0
                presentedRightPaneOpacity = isVisible ? 1 : 0
            }
        }
        .onChange(of: workspace.isBottomVisible) { _, isVisible in
            updatePanePresentation {
                presentedBottomPaneHeight = isVisible
                    ? min(workspace.bottomPaneHeight, maximumBottomPaneHeight)
                    : 0
                presentedBottomPaneOpacity = isVisible ? 1 : 0
            }
        }
        .onChange(of: maximumBottomPaneHeight) { _, newMaximum in
            guard workspace.isBottomVisible else { return }
            presentedBottomPaneHeight = min(workspace.bottomPaneHeight, newMaximum)
        }
    }

    @ViewBuilder
    private func centerStack(maximumBottomPaneHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            pane(.main)
                .frame(minHeight: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            pane(.bottom)
                .frame(height: presentedBottomPaneHeight)
                .opacity(presentedBottomPaneOpacity)
                .clipped()
                .allowsHitTesting(workspace.isBottomVisible)
                .accessibilityHidden(!workspace.isBottomVisible)
        }
        .overlay {
            GeometryReader { geometry in
                bottomDivider(maximumHeight: maximumBottomPaneHeight)
                    .frame(width: geometry.size.width)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height - presentedBottomPaneHeight
                    )
                    .allowsHitTesting(workspace.isBottomVisible)
                    .accessibilityHidden(!workspace.isBottomVisible)
            }
        }
    }

    private func updatePanePresentation(_ update: () -> Void) {
        if reduceMotion {
            update()
        } else {
            withAnimation(QuietReaderMotion.workspacePanel, update)
        }
    }

    private var rightDivider: some View {
        Color.clear
            .frame(width: WorkspacePaneSizing.dividerHitArea)
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)
            }
            .opacity(presentedRightPaneOpacity)
            .contentShape(Rectangle())
            .gesture(rightResizeGesture)
            .paneResizeCursor(.horizontal, isDragging: $isRightResizing)
            .accessibilityElement()
            .accessibilityLabel("Resize right pane")
            .accessibilityValue("\(Int(presentedRightPaneWidth)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    workspace.rightPaneWidth = min(640, workspace.rightPaneWidth + 20)
                case .decrement:
                    workspace.rightPaneWidth = max(280, workspace.rightPaneWidth - 20)
                @unknown default:
                    break
                }
                presentedRightPaneWidth = workspace.rightPaneWidth
            }
            .accessibilityHidden(!workspace.isRightVisible)
    }

    private func bottomDivider(maximumHeight: CGFloat) -> some View {
        Color.clear
            .frame(height: WorkspacePaneSizing.dividerHitArea)
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
            }
            .opacity(presentedBottomPaneOpacity)
            .contentShape(Rectangle())
            .gesture(bottomResizeGesture(maximumHeight: maximumHeight))
            .paneResizeCursor(.vertical, isDragging: $isBottomResizing)
            .accessibilityElement()
            .accessibilityLabel("Resize bottom pane")
            .accessibilityValue("\(Int(presentedBottomPaneHeight)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    workspace.bottomPaneHeight = min(
                        maximumHeight,
                        presentedBottomPaneHeight + 20
                    )
                case .decrement:
                    workspace.bottomPaneHeight = max(
                        WorkspacePaneSizing.minimumBottomPaneHeight,
                        presentedBottomPaneHeight - 20
                    )
                @unknown default:
                    break
                }
                presentedBottomPaneHeight = workspace.bottomPaneHeight
            }
            .accessibilityHidden(!workspace.isBottomVisible)
    }

    private var rightResizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isRightResizing {
                    isRightResizing = true
                    activatePaneResizeCursor(.horizontal)
                }
                let start = rightResizeStart ?? presentedRightPaneWidth
                rightResizeStart = start
                presentedRightPaneWidth = min(640, max(280, start - value.translation.width))
            }
            .onEnded { _ in
                workspace.rightPaneWidth = presentedRightPaneWidth
                rightResizeStart = nil
                isRightResizing = false
            }
    }

    private func bottomResizeGesture(maximumHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isBottomResizing {
                    isBottomResizing = true
                    activatePaneResizeCursor(.vertical)
                }
                let start = bottomResizeStart ?? presentedBottomPaneHeight
                bottomResizeStart = start
                presentedBottomPaneHeight = min(
                    maximumHeight,
                    max(
                        WorkspacePaneSizing.minimumBottomPaneHeight,
                        start - value.translation.height
                    )
                )
            }
            .onEnded { _ in
                workspace.bottomPaneHeight = presentedBottomPaneHeight
                bottomResizeStart = nil
                isBottomResizing = false
            }
    }

    private func activatePaneResizeCursor(_ cursor: PaneResizeCursor) {
        #if os(macOS)
        cursor.nativeCursor.set()
        #endif
    }

    private func pane(_ paneID: WorkspacePaneID) -> some View {
        WorkspacePaneView(
            paneID: paneID,
            pane: workspace.pane(paneID),
            rootBookID: rootBookID,
            library: library,
            workspace: workspace,
            account: account,
            preferences: preferences,
            openType: openType,
            closeWorkspace: closeWorkspace
        )
    }
}

private enum PaneResizeCursor {
    case horizontal
    case vertical
}

private extension View {
    @ViewBuilder
    func paneResizeCursor(
        _ cursor: PaneResizeCursor,
        isDragging: Binding<Bool>
    ) -> some View {
        #if os(macOS)
        modifier(PaneResizeCursorModifier(cursor: cursor, isDragging: isDragging))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct PaneResizeCursorModifier: ViewModifier {
    let cursor: PaneResizeCursor
    @Binding var isDragging: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    cursor.nativeCursor.set()
                } else if !isDragging {
                    NSCursor.arrow.set()
                }
            }
            .onChange(of: isDragging) { _, dragging in
                if dragging || isHovering {
                    cursor.nativeCursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onDisappear {
                if isHovering || isDragging {
                    NSCursor.arrow.set()
                }
            }
    }
}

private extension PaneResizeCursor {
    var nativeCursor: NSCursor {
        switch self {
        case .horizontal:
            .resizeLeftRight
        case .vertical:
            .resizeUpDown
        }
    }
}
#endif

private struct WorkspacePaneView: View {
    let paneID: WorkspacePaneID
    let pane: WorkspacePaneState
    let rootBookID: UUID
    @Bindable var library: LibraryModel
    @Bindable var workspace: WorkspaceModel
    @Bindable var account: ReaderAccountModel
    let preferences: QuietReadingPreferences
    let openType: () -> Void
    let closeWorkspace: () -> Void

    private var selectedTab: WorkspaceTab? {
        pane.tabs.first { $0.id == pane.selectedTabID } ?? pane.tabs.first
    }

    private var showsTabBar: Bool {
        paneID == .main || !pane.tabs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsTabBar {
                WorkspaceTabBar(
                    paneID: paneID,
                    pane: pane,
                    workspace: workspace,
                    closeTab: close,
                    openBook: openBook
                )

                Divider()
            }

            Group {
                if let selectedTab {
                    content(for: selectedTab)
                        .id(selectedTab.id)
                } else {
                    WorkspaceEmptyView(
                        openBook: openBook,
                        openBrowser: { workspace.openBrowser(in: paneID) },
                        openChat: { workspace.openChat(in: paneID) },
                        openDictionary: { workspace.openDictionary(in: paneID) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ReaderColors.canvas)
        .dropDestination(for: String.self) { items, _ in
            guard
                let rawID = items.first,
                let tabID = UUID(uuidString: rawID)
            else { return false }
            workspace.move(tabID, to: paneID)
            return true
        }
    }

    @ViewBuilder
    private func content(for tab: WorkspaceTab) -> some View {
        switch tab.kind {
        case .book(let bookID):
            if let book = library.books.first(where: { $0.id == bookID }) {
                if book.publication != nil {
                    PublicationReaderContainerView(
                        book: book,
                        library: library,
                        account: account,
                        preferences: preferences,
                        askSelection: { source in
                            workspace.openHighlightQuestion(source, in: .right)
                        },
                        selectionChanged: { source in
                            workspace.attachSelectionToVisibleAssistant(source)
                        },
                        rewriteSelection: { source, command in
#if DEBUG
                            if ProcessInfo.processInfo.arguments.contains(
                                "--quiet-reader-inline-rewrite-demo"
                            ) {
                                try await Task.sleep(for: .seconds(2.1))
                                return ReaderInlineRewritePreview.response(
                                    for: source.selection.selectedText,
                                    command: command
                                )
                            }
#endif
                            let answer = try await account.answerHighlightQuestion(
                                HighlightQuestionRequest(
                                    question: command.question,
                                    draft: source
                                )
                            )
                            return answer.text
                        },
                        defineSelection: { word in
                            guard let term = ReaderDictionaryTerm(word) else { return }
                            workspace.openDictionary(for: term, in: .right)
                        },
                        openType: openType,
                        close: { close(tab) }
                    )
                } else {
                    ReaderView(book: book) {
                        close(tab)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Book unavailable",
                    systemImage: "book.closed",
                    description: Text("The local file for this tab is no longer in the library.")
                )
            }

        case .browser:
            let session = workspace.browserSession(for: tab.id)
            BrowserWorkspaceView(session: session)
                .onChange(of: session.title) { _, title in
                    workspace.rename(tab.id, to: title)
                }

        case .chat:
            ReaderAssistantView(
                session: workspace.assistantSession(for: tab.id),
                account: account,
                loadBookKnowledge: {
                    library.bookKnowledge(for: rootBookID)
                }
            )

        case .dictionary:
            DictionaryWorkspaceView(
                session: workspace.dictionarySession(for: tab.id),
                renameTab: { workspace.rename(tab.id, to: $0) }
            )
        }
    }

    private func openBook() {
        workspace.pendingImportPane = paneID
        library.showImporter = true
    }

    private func close(_ tab: WorkspaceTab) {
        if paneID == .main, tab.kind == .book(rootBookID) {
            workspace.close(tab.id, in: paneID)
            closeWorkspace()
        } else {
            workspace.close(tab.id, in: paneID)
        }
    }
}

#if DEBUG
enum ReaderInlineRewritePreview {
    static func response(
        for selectedText: String,
        command: ReaderRewriteCommand
    ) -> String {
        let normalized = selectedText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "in order to", with: "to", options: .caseInsensitive)
            .replacingOccurrences(of: "due to the fact that", with: "because", options: .caseInsensitive)
            .replacingOccurrences(of: "utilize", with: "use", options: .caseInsensitive)

        guard let instruction = command.instruction?.lowercased() else {
            if normalized.hasPrefix("The small discovery should feel immediate.") {
                return "A small discovery should feel instant. The word stays on the page while its definition appears nearby, keeping everything else calm."
            }
            return "Put simply, \(normalized.prefix(260))"
        }
        if instruction.contains("short") || instruction.contains("concise") {
            let firstSentence = normalized.split(separator: ".", maxSplits: 1).first
                .map(String.init) ?? normalized
            return String(firstSentence.prefix(180)).trimmingCharacters(
                in: .whitespacesAndNewlines
            ) + "."
        }
        if instruction.contains("poetic") || instruction.contains("lyrical") {
            return "Like a quiet page turning, \(normalized.prefix(220))"
        }
        return "\(normalized)"
    }
}
#endif

private struct WorkspaceEmptyView: View {
    let openBook: () -> Void
    let openBrowser: () -> Void
    let openChat: () -> Void
    let openDictionary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaneChoice(
                title: "open another book",
                action: openBook
            )
            PaneChoice(
                title: "browser",
                action: openBrowser
            )
            PaneChoice(
                title: "AI chat",
                action: openChat
            )
            PaneChoice(
                title: "dictionary",
                action: openDictionary
            )
        }
        .frame(maxWidth: 360, alignment: .leading)
        .offset(y: 21)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderColors.canvas)
    }
}

private struct PaneChoice: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .light).italic())
                .foregroundStyle(isHovered ? ReaderColors.ink : ReaderColors.voiceQuiet)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 32)
                .padding(.leading, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(title)
    }
}

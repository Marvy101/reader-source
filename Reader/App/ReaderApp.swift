import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct ReaderApp: App {
    @State private var model: LibraryModel
    @State private var account: ReaderAccountModel
    private let isFoundationPreview: Bool
    private let isCatalogDemo: Bool

    init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let preview = arguments.contains(
            "--quiet-reader-foundation-preview"
        )
        let configuredPreviewRoot = Bundle.main.object(
            forInfoDictionaryKey: "ReaderLibraryPreviewRoot"
        ) as? String
        let demoSession = arguments.contains("--quiet-reader-demo-session")
            || configuredPreviewRoot != nil
        let libraryDemo = arguments.contains("--quiet-reader-library-ui-demo")
            || configuredPreviewRoot != nil
        let catalogDemo = arguments.contains("--quiet-reader-catalog-ui-demo")
        let ephemeralAuth = arguments.contains("--quiet-reader-ephemeral-auth")
        let demoRoot = Self.argumentValue(
            after: "--quiet-reader-library-root",
            in: arguments
        ) ?? configuredPreviewRoot
#else
        let preview = false
        let demoSession = false
        let libraryDemo = false
        let catalogDemo = false
        let ephemeralAuth = false
        let demoRoot: String? = nil
#endif
        let testHost = NSClassFromString("XCTestCase") != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        isFoundationPreview = preview
        isCatalogDemo = catalogDemo

        if preview || testHost || demoSession || ephemeralAuth {
            let demoModel: LibraryModel
            if let demoRoot,
               let store = try? ReaderLibraryStore(rootURL: URL(fileURLWithPath: demoRoot)),
               let storedModel = try? LibraryModel(store: store) {
                demoModel = storedModel
            } else {
                demoModel = LibraryModel(books: [])
            }
            if libraryDemo {
                demoModel.installLibraryPreview()
            }
            _model = State(initialValue: demoModel)
            let session = demoSession
                ? ReaderAuthSession(
                    accessToken: "local-preview",
                    refreshToken: "local-preview",
                    expiresAt: nil,
                    user: ReaderAuthUser(
                        id: "quiet-reader-preview",
                        email: "preview@reader.local"
                    )
                )
                : nil
            _account = State(
                initialValue: ReaderAccountModel(
                    backend: ReaderBackendClient.live(),
                    credentialStore: FoundationPreviewCredentialStore(session: session),
                    onlineRequestDisabledMessage: demoSession
                        ? "This visual preview isn't connected to AI. Open a signed-in Reader build to chat."
                        : nil
                )
            )
        } else {
            _model = State(initialValue: LibraryModel.live())
            _account = State(initialValue: ReaderAccountModel.live())
        }
    }

    private static func argumentValue(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard
            let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if isFoundationPreview {
                    QuietReaderFoundationPreview()
                } else {
                    RootView(
                        model: model,
                        account: account,
                        catalogDemoMode: isCatalogDemo
                    )
                }
#else
                RootView(model: model, account: account)
#endif
            }
            .frame(minWidth: 980, minHeight: 680)
#if os(macOS)
            .background(WindowChromeConfigurator())
#endif
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Books…") {
                    model.showImporter = true
                }
                .keyboardShortcut("o")
                .disabled(!account.isAuthenticated)
            }

            QuietReaderNavigationCommands()
            ReaderReadingCommands()
            ReaderZoomCommands()
        }

        Settings {
            QuietSettingsWindow()
                .frame(width: 760, height: 520)
        }
    }
}

struct QuietReaderActions {
    let importFiles: () -> Void
    let search: () -> Void
    let library: () -> Void
    let type: () -> Void
    let openBrowserRight: () -> Void
    let openBrowserBottom: () -> Void
    let openAIRight: () -> Void
    let openAIBottom: () -> Void
    let toggleRightPane: () -> Void
    let toggleBottomPane: () -> Void
}

private struct QuietReaderActionsKey: FocusedValueKey {
    typealias Value = QuietReaderActions
}

extension FocusedValues {
    var quietReaderActions: QuietReaderActions? {
        get { self[QuietReaderActionsKey.self] }
        set { self[QuietReaderActionsKey.self] = newValue }
    }
}

private struct QuietReaderNavigationCommands: Commands {
    @FocusedValue(\.quietReaderActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Search Everything") { actions?.search() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(actions == nil)
        }

        CommandMenu("Go") {
            Button("Library") { actions?.library() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Search") { actions?.search() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Open Browser in Right Pane") { actions?.openBrowserRight() }
            Button("Open Browser in Bottom Pane") { actions?.openBrowserBottom() }
            Button("Open AI in Right Pane") { actions?.openAIRight() }
            Button("Open AI in Bottom Pane") { actions?.openAIBottom() }
        }

        CommandGroup(after: .toolbar) {
            Button("Reading Type…") { actions?.type() }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Right Pane") { actions?.toggleRightPane() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Toggle Bottom Pane") { actions?.toggleBottomPane() }
                .keyboardShortcut("b", modifiers: [.command, .option])
        }
    }
}

private struct QuietSettingsWindow: View {
    @State private var state = QuietReaderState()

    var body: some View {
        QuietTypeScreen(preferences: $state.preferences) {}
    }
}

private struct FoundationPreviewCredentialStore: ReaderCredentialStoring {
    let session: ReaderAuthSession?

    init(session: ReaderAuthSession? = nil) {
        self.session = session
    }

    func load() throws -> ReaderAuthSession? { session }
    func save(_ session: ReaderAuthSession) throws {}
    func remove() throws {}
}

struct ReaderZoomActions {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let actualSize: () -> Void
}

struct ReaderReadingActions {
    let contents: () -> Void
    let find: () -> Void
    let keep: () -> Void
    let note: () -> Void
    let ask: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
}

private struct ReaderReadingActionsKey: FocusedValueKey {
    typealias Value = ReaderReadingActions
}

extension FocusedValues {
    var readerReadingActions: ReaderReadingActions? {
        get { self[ReaderReadingActionsKey.self] }
        set { self[ReaderReadingActionsKey.self] = newValue }
    }
}

private struct ReaderReadingCommands: Commands {
    @FocusedValue(\.readerReadingActions) private var actions

    var body: some Commands {
        CommandMenu("Reading") {
            Button("Contents") { actions?.contents() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Find in Book") { actions?.find() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Keep Selection") { actions?.keep() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Note Selection") { actions?.note() }
            Button("Ask About Selection") { actions?.ask() }
            Divider()
            Button("Previous Page") { actions?.previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next Page") { actions?.nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
    }
}

private struct ReaderZoomActionsKey: FocusedValueKey {
    typealias Value = ReaderZoomActions
}

extension FocusedValues {
    var readerZoomActions: ReaderZoomActions? {
        get { self[ReaderZoomActionsKey.self] }
        set { self[ReaderZoomActionsKey.self] = newValue }
    }
}

private struct ReaderZoomCommands: Commands {
    @FocusedValue(\.readerZoomActions) private var actions

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()

            Button("Zoom In") {
                actions?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(actions == nil)

            Button("Zoom Out") {
                actions?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(actions == nil)

            Button("Actual Size") {
                actions?.actualSize()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(actions == nil)
        }
    }
}

#if os(macOS)
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView {
        WindowChromeView()
    }

    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.configureWindow()
    }

    final class WindowChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }

            window.styleMask.insert([
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ])
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }
}
#endif

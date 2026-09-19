import SwiftUI

struct BrowserWorkspaceView: View {
    @Bindable var session: BrowserSession

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Divider()

            if session.currentURL == nil {
                emptyState
            } else {
                NativeBrowserSurface(session: session)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var browserToolbar: some View {
        HStack(spacing: 13) {
            Button(action: session.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!session.canGoBack)
            .help("Back")

            Button(action: session.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!session.canGoForward)
            .help("Forward")

            Button(action: session.reloadOrStop) {
                Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(session.currentURL == nil)
            .help(session.isLoading ? "Stop" : "Reload")

            TextField("Search or enter website name", text: $session.addressText)
                .textFieldStyle(.plain)
                .onSubmit(session.navigateFromAddressBar)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(
                    Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            Menu {
                Button("Open in Safari") {
                    guard let url = session.currentURL else { return }
                    NSWorkspace.shared.open(url)
                }
                .disabled(session.currentURL == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)

            Text("Start browsing")
                .font(.system(size: 24, weight: .semibold))

            Text("Enter a URL to open a page")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

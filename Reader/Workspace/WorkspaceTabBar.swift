import SwiftUI

struct WorkspaceTabBar: View {
    let paneID: WorkspacePaneID
    let pane: WorkspacePaneState
    @Bindable var workspace: WorkspaceModel
    let closeTab: (WorkspaceTab) -> Void
    let openBook: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(pane.tabs) { tab in
                        tabButton(tab)
                            .transition(tabTransition)
                    }
                }
                .padding(.leading, 12)
                .animation(tabAnimation, value: pane.tabs.map(\.id))
            }
            .scrollIndicators(.never)

            Menu {
                Button(action: openBook) {
                    Label("Open Book…", systemImage: "book.closed")
                }

                Button {
                    workspace.openBrowser(in: paneID)
                } label: {
                    Label("Browser", systemImage: "globe")
                }

                Button {
                    workspace.openChat(in: paneID)
                } label: {
                    Label("Chat", systemImage: "message")
                }

                Button {
                    workspace.openDictionary(in: paneID)
                } label: {
                    Label("Dictionary", systemImage: "book")
                }
            } label: {
                WorkspaceNewTabLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New tab")

            Spacer(minLength: 8)

            if paneID == .main {
                HStack(spacing: QuietUtilityControl.gap) {
                    WorkspacePaneToggle(
                        systemName: "rectangle.split.1x2",
                        isSelected: workspace.isBottomVisible,
                        help: workspace.isBottomVisible ? "Hide bottom pane" : "Show bottom pane",
                        action: workspace.toggleBottom
                    )

                    WorkspacePaneToggle(
                        systemName: "rectangle.split.2x1",
                        isSelected: workspace.isRightVisible,
                        help: workspace.isRightVisible ? "Hide right pane" : "Show right pane",
                        action: workspace.toggleRight
                    )
                }
                .padding(.trailing, 12)
            }
        }
        .frame(height: 50)
        .background(.bar)
    }

    private func tabButton(_ tab: WorkspaceTab) -> some View {
        let isSelected = pane.selectedTabID == tab.id

        return HStack(spacing: 9) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 14, weight: .regular))

            Text(tab.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Button {
                closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close tab")
        }
        .foregroundStyle(ReaderColors.ink)
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .frame(height: 36)
        .frame(maxWidth: 220)
        .background(
            isSelected ? Color.primary.opacity(0.065) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            workspace.select(tab.id, in: paneID)
        }
        .draggable(tab.id.uuidString)
        .contextMenu {
            Button("Move to Main") { workspace.move(tab.id, to: .main) }
                .disabled(paneID == .main)
            Button("Move to Bottom") { workspace.move(tab.id, to: .bottom) }
                .disabled(paneID == .bottom)
            Button("Move to Right") { workspace.move(tab.id, to: .right) }
                .disabled(paneID == .right)
            Divider()
            Button("Close") { closeTab(tab) }
        }
    }

    private var tabAnimation: Animation? {
        reduceMotion ? nil : QuietReaderMotion.workspaceTab
    }

    private var tabTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .leading)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        )
    }

}

private struct WorkspaceNewTabLabel: View {
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: QuietUtilityControl.symbolSize, weight: .regular))
            .foregroundStyle(
                QuietUtilityControl.restingInk
            )
            .frame(width: QuietUtilityControl.size, height: QuietUtilityControl.size)
            .background(
                isHovered ? QuietUtilityControl.hoverBackground : .clear,
                in: RoundedRectangle(
                    cornerRadius: QuietUtilityControl.cornerRadius,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: QuietUtilityControl.cornerRadius,
                    style: .continuous
                )
            )
            .onHover { isHovered = $0 }
    }
}

private struct WorkspacePaneToggle: View {
    let systemName: String
    let isSelected: Bool
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: QuietUtilityControl.symbolSize, weight: .regular))
                .foregroundStyle(
                    isSelected
                        ? QuietUtilityControl.activeInk
                        : QuietUtilityControl.restingInk
                )
                .frame(width: QuietUtilityControl.size, height: QuietUtilityControl.size)
                .background(
                    background,
                    in: RoundedRectangle(
                        cornerRadius: QuietUtilityControl.cornerRadius,
                        style: .continuous
                    )
                )
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: QuietUtilityControl.cornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isSelected ? "On" : "Off")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected && isHovered { return QuietUtilityControl.selectedHoverBackground }
        if isSelected { return QuietUtilityControl.selectedBackground }
        if isHovered { return QuietUtilityControl.hoverBackground }
        return .clear
    }
}

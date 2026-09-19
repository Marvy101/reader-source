import SwiftUI

enum ReaderSelectionPanelMode: Equatable {
    case actions
    case colors
    case note
    case copied
    case rewrite
}

enum ReaderSelectionRewriteState: Equatable {
    case idle
    case loading
    case result(String)
    case failed(String)
}

struct ReaderSelectionActionAvailability: Equatable {
    let canDefine: Bool
    let canRewriteWithAI: Bool

    init(selectedText: String) {
        let isSingleWord = ReaderDictionaryTerm(selectedText)?.isSingleWord == true
        canDefine = isSingleWord
        canRewriteWithAI = !isSingleWord
    }
}

struct ReaderSelectionPanel: View {
    let selection: ReaderSelection
    let canDefine: Bool
    let canRewriteWithAI: Bool
    let theme: QuietReadingTheme
    let mode: ReaderSelectionPanelMode
    let rewriteState: ReaderSelectionRewriteState
    let highlightColor: ReaderHighlightColor
    @Binding var noteDraft: String
    let highlight: () -> Void
    let showHighlightColors: () -> Void
    let chooseHighlightColor: (ReaderHighlightColor) -> Void
    let showDefinition: () -> Void
    let keep: () -> Void
    let beginNote: () -> Void
    let copy: () -> Void
    let ask: () -> Void
    let rewriteWithAI: () -> Void
    let saveNote: () -> Void
    @FocusState private var noteIsFocused: Bool

    var body: some View {
        actionCard
            .overlay(alignment: .top) {
                ZStack {
                    if mode == .colors {
                        highlightPalette
                            .offset(y: 62)
                            .transition(
                                .opacity.combined(with: .offset(y: -8))
                            )
                            .zIndex(1)
                    }
                }
                .animation(.easeOut(duration: 0.16), value: mode == .colors)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Selection actions for \(selection.selectedText)")
            .onChange(of: mode) { _, updatedMode in
                guard updatedMode == .note else {
                    noteIsFocused = false
                    return
                }
                Task { @MainActor in noteIsFocused = true }
            }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            actionBar

            switch mode {
            case .actions, .colors:
                EmptyView()
            case .note:
                noteBody
            case .copied:
                QuietVoiceText(
                    text: "copied to clipboard",
                    size: 12,
                    color: theme.ink.opacity(0.58)
                )
            case .rewrite:
                rewriteBody
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            theme.background.opacity(0.98),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(theme.ink.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.13), radius: 18, y: 7)
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            HighlightColorMenuButton(
                color: highlightColor,
                theme: theme,
                isExpanded: mode == .colors,
                action: showHighlightColors
            )

            QuietActionWord(
                title: "highlight",
                restingColor: theme.ink.opacity(0.52),
                activeColor: theme.ink,
                action: highlight
            )

            if canDefine {
                QuietActionWord(
                    title: "define",
                    restingColor: theme.ink.opacity(0.52),
                    activeColor: theme.ink,
                    action: showDefinition
                )
            }

            if canRewriteWithAI {
                QuietActionWord(
                    title: "rewrite with ai",
                    restingColor: theme.ink.opacity(0.52),
                    activeColor: theme.ink,
                    isSelected: mode == .rewrite,
                    action: rewriteWithAI
                )
            }

            QuietActionWord(
                title: "keep",
                restingColor: theme.ink.opacity(0.52),
                activeColor: theme.ink,
                action: keep
            )
            QuietActionWord(
                title: "note",
                restingColor: theme.ink.opacity(0.52),
                activeColor: theme.ink,
                isSelected: mode == .note,
                action: beginNote
            )
            QuietActionWord(
                title: "copy",
                restingColor: theme.ink.opacity(0.52),
                activeColor: theme.ink,
                action: copy
            )
            QuietActionWord(
                title: "ask",
                restingColor: theme.ink.opacity(0.52),
                activeColor: theme.ink,
                action: ask
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var highlightPalette: some View {
        HStack(spacing: 22) {
            ForEach(ReaderHighlightColor.allCases, id: \.self) { color in
                Button {
                    chooseHighlightColor(color)
                } label: {
                    VStack(spacing: 7) {
                        ZStack {
                            if color == highlightColor {
                                Circle()
                                    .stroke(theme.ink.opacity(0.28), lineWidth: 1.5)
                                    .frame(width: 38, height: 38)
                            }

                            Circle()
                                .fill(color.swiftUIColor)
                                .overlay {
                                    Circle()
                                        .stroke(theme.ink.opacity(0.13), lineWidth: 1)
                                }
                                .frame(width: 30, height: 30)
                        }
                        .frame(width: 38, height: 38)

                        Text(color.displayName)
                            .font(QuietReaderTypography.appVoice(size: 12))
                            .tracking(QuietReaderTypography.tracking(for: 12))
                            .foregroundStyle(theme.ink.opacity(0.72))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(color.displayName) highlight")
                .accessibilityValue(color == highlightColor ? "selected" : "")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(
            theme.background.opacity(0.98),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(theme.ink.opacity(0.10))
        }
        .shadow(color: .black.opacity(0.13), radius: 18, y: 7)
        .fixedSize()
    }

    private var noteBody: some View {
        VStack(alignment: .leading, spacing: 11) {
            Divider()
                .overlay(theme.ink.opacity(0.08))

            HStack(alignment: .bottom, spacing: 14) {
                TextField("write a note", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(QuietReaderTypography.content(size: 14))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1...3)
                    .focused($noteIsFocused)
                    .onSubmit(saveNote)

                QuietActionWord(
                    title: "save",
                    restingColor: theme.ink.opacity(0.52),
                    activeColor: theme.ink,
                    action: saveNote
                )
            }
        }
    }

    @ViewBuilder
    private var rewriteBody: some View {
        VStack(alignment: .leading, spacing: 11) {
            Divider()
                .overlay(theme.ink.opacity(0.08))

            switch rewriteState {
            case .idle, .loading:
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    QuietVoiceText(
                        text: "rewriting with ai",
                        size: 12,
                        color: theme.ink.opacity(0.58)
                    )
                }
            case .result(let text):
                ScrollView {
                    Text(text)
                        .font(QuietReaderTypography.content(size: 14))
                        .foregroundStyle(theme.ink.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 160)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 9) {
                    QuietVoiceText(
                        text: message,
                        size: 12,
                        color: theme.ink.opacity(0.58)
                    )
                    QuietActionWord(
                        title: "try again",
                        restingColor: theme.ink.opacity(0.52),
                        activeColor: theme.ink,
                        action: rewriteWithAI
                    )
                }
            }
        }
    }
}

private struct HighlightColorMenuButton: View {
    let color: ReaderHighlightColor
    let theme: QuietReadingTheme
    let isExpanded: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color.swiftUIColor)
                    .overlay {
                        Circle()
                            .stroke(theme.ink.opacity(0.15), lineWidth: 1)
                    }
                    .frame(width: 20, height: 20)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(isHovered || isExpanded ? 0.72 : 0.42))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Highlight color")
        .accessibilityValue(color.displayName)
        .accessibilityHint(isExpanded ? "Closes color choices" : "Opens color choices")
    }
}

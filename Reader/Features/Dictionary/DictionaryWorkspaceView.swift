import SwiftUI

struct DictionaryWorkspaceView: View {
    @Bindable var session: ReaderDictionarySession
    let renameTab: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchIsFocused: Bool
    @State private var revealedCharacterCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuietVoiceText(
                text: "dictionary",
                size: 12,
                color: ReaderColors.voiceQuiet
            )
            .padding(.bottom, 18)

            TextField(
                "look up a word",
                text: Binding(
                    get: { session.searchText },
                    set: { value in
                        session.updateSearchTextFromUser(value)
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(QuietReaderTypography.content(size: 22))
            .foregroundStyle(ReaderColors.ink)
            .focused($searchIsFocused)
            .onSubmit(submit)
            .accessibilityLabel("Dictionary word")

            Rectangle()
                .fill(ReaderColors.ink.opacity(searchIsFocused ? 0.34 : 0.12))
                .frame(height: 1)
                .padding(.top, 8)
                .padding(.bottom, 24)

            definition
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReaderColors.canvas)
        .task(id: session.entry?.definition) {
            await revealDefinition()
        }
    }

    @ViewBuilder
    private var definition: some View {
        if let entry = session.entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if entry.presentation.variant != nil
                        || !entry.presentation.pronunciations.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if let variant = entry.presentation.variant {
                                Text(variant)
                            }
                            if !entry.presentation.pronunciations.isEmpty {
                                Text(entry.presentation.pronunciations.joined(separator: " · "))
                            }
                        }
                        .font(QuietReaderTypography.content(size: 13))
                        .foregroundStyle(ReaderColors.ink.opacity(0.56))
                    }

                    ForEach(Array(entry.presentation.sections.enumerated()), id: \.element.id) {
                        index, section in
                        let start = sectionStart(index, in: entry.presentation.sections)
                        if revealedCharacterCount >= start {
                            VStack(alignment: .leading, spacing: 8) {
                                QuietVoiceText(
                                    text: section.title,
                                    size: 12,
                                    color: ReaderColors.voiceQuiet
                                )

                                Text(revealedBody(
                                    section.body,
                                    startingAt: start
                                ))
                                .font(QuietReaderTypography.content(size: 15))
                                .tracking(QuietReaderTypography.tracking(for: 15))
                                .foregroundStyle(ReaderColors.ink.opacity(0.90))
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(section.body)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        } else if session.lookupWasAttempted {
            QuietVoiceText(
                text: "no definition in your active dictionaries",
                size: 13,
                color: ReaderColors.voiceQuiet
            )
        } else {
            QuietVoiceText(
                text: "type a word and press return",
                size: 13,
                color: ReaderColors.voiceQuiet
            )
        }
    }

    private func submit() {
        session.submitManualLookup()
        let word = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTab(word.isEmpty ? "Dictionary" : "Dictionary · \(word)")
    }

    @MainActor
    private func revealDefinition() async {
        guard session.entry != nil else {
            revealedCharacterCount = 0
            return
        }
        let sections = session.entry?.presentation.sections ?? []
        let characterCount = sections.reduce(0) { $0 + $1.body.count }
        guard !reduceMotion else {
            revealedCharacterCount = characterCount
            return
        }

        let charactersPerFrame = max(1, (characterCount + 179) / 180)
        revealedCharacterCount = 0

        while revealedCharacterCount < characterCount, !Task.isCancelled {
            revealedCharacterCount = min(
                revealedCharacterCount + charactersPerFrame,
                characterCount
            )
            try? await Task.sleep(for: .milliseconds(14))
        }
    }

    private func sectionStart(
        _ index: Int,
        in sections: [ReaderDictionarySection]
    ) -> Int {
        sections.prefix(index).reduce(0) { $0 + $1.body.count }
    }

    private func revealedBody(_ body: String, startingAt start: Int) -> String {
        let available = max(0, min(body.count, revealedCharacterCount - start))
        return String(body.prefix(available))
    }
}

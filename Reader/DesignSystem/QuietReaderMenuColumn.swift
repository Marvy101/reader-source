import SwiftUI

enum QuietReaderMenuItem: String, CaseIterable, Hashable, Sendable {
    case search
    case everything
    case reading
    case papers
    case finished
    case kept
    case ai
}

struct QuietReaderMenuColumn: View {
    let selection: QuietReaderMenuItem
    let mark: QuietAccountMark
    let select: (QuietReaderMenuItem) -> Void
    let openAccount: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: QuietReaderMetric.menuGap) {
                menuWord(.search)
                    .padding(.bottom, QuietReaderMetric.menuSearchExtraGap)

                menuWord(.everything)
                menuWord(.reading)
                menuWord(.papers)
                menuWord(.finished)
                menuWord(.kept)
                menuWord(.ai)
            }
            .padding(.leading, QuietReaderMetric.windowHorizontalMargin)
            .padding(.top, QuietReaderMetric.menuTop)

            Button(action: openAccount) {
                QuietAccountMarkView(mark: mark, size: 28)
                    .opacity(0.85)
            }
            .buttonStyle(.plain)
            .padding(.leading, QuietReaderMetric.windowHorizontalMargin)
            .padding(.bottom, QuietReaderMetric.menuAccountBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .accessibilityLabel("account")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func menuWord(_ item: QuietReaderMenuItem) -> some View {
        QuietMenuWord(
            title: item.rawValue,
            isSelected: selection == item
        ) {
            select(item)
        }
    }
}

private struct QuietMenuWord: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(QuietReaderTypography.appVoice(size: 13))
                .tracking(QuietReaderTypography.tracking(for: 13))
                .foregroundStyle(
                    isSelected || isHovered
                        ? QuietReaderColor.ink
                        : QuietReaderColor.voiceQuiet
                )
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

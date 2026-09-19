import SwiftUI

struct ReaderView: View {
    let book: Book
    let close: () -> Void

    @State private var showChrome = true
    @State private var textScale = 1.0

    var body: some View {
        ZStack {
            ReaderColors.canvas
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    readingPage
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 42)
                .padding(.vertical, 48)
            }
            .scrollIndicators(.never)
        }
        .toolbar {
            if showChrome {
                ToolbarItem(placement: .navigation) {
                    Button(action: close) {
                        Label("Library", systemImage: "chevron.left")
                    }
                    .help("Back to library")
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(book.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(book.author)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        textScale = max(0.85, textScale - 0.05)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .help("Smaller text")

                    Button {
                        textScale = min(1.3, textScale + 0.05)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .help("Larger text")

                    Button {
                        showChrome.toggle()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Focus mode")
                }
            }
        }
        .onExitCommand(perform: close)
        .overlay(alignment: .topTrailing) {
            if !showChrome {
                Button {
                    showChrome = true
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(11)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(18)
                .help("Leave focus mode")
            }
        }
    }

    private var readingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(book.sample.chapter.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(ReaderColors.moss)
                .padding(.bottom, 20)

            Text(book.sample.section)
                .font(.system(size: 38 * textScale, weight: .semibold, design: .serif))
                .foregroundStyle(ReaderColors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)

            Rectangle()
                .fill(ReaderColors.ink.opacity(0.58))
                .frame(width: 34, height: 1)
                .padding(.bottom, 34)

            VStack(alignment: .leading, spacing: 22 * textScale) {
                ForEach(Array(book.sample.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .font(.system(size: 20 * textScale, design: .serif))
                        .foregroundStyle(ReaderColors.ink.opacity(0.92))
                        .lineSpacing(9 * textScale)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(index == 0 ? "Beginning: \(paragraph)" : paragraph)
                }
            }

            HStack {
                Rectangle()
                    .fill(ReaderColors.hairline)
                    .frame(height: 1)

                Text("\(Int(book.progress * 100))%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Rectangle()
                    .fill(ReaderColors.hairline)
                    .frame(height: 1)
            }
            .padding(.top, 56)
        }
        .padding(.horizontal, 70)
        .padding(.top, 72)
        .padding(.bottom, 56)
        .frame(maxWidth: 720, minHeight: 820, alignment: .topLeading)
        .background(ReaderColors.paper, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 24, y: 12)
    }
}

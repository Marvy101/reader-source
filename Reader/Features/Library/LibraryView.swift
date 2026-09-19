import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    let openBook: (Book) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 148, maximum: 178), spacing: 30, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                header

                if model.searchText.isEmpty, let currentBook = model.currentBook {
                    ContinueReadingCard(book: currentBook) {
                        openBook(currentBook)
                    }
                }

                booksSection
            }
            .padding(.horizontal, 42)
            .padding(.top, 36)
            .padding(.bottom, 60)
            .frame(maxWidth: 1160, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(ReaderColors.canvas)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.destination == .readingNow ? "Reading now" : "Library")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(ReaderColors.ink)

                Text("A quiet place for the books that stay with you.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Search your library", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .padding(.top, 5)

            Button {
                model.showImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            .help("Add books")
            .accessibilityLabel("Add books")
        }
    }

    private var booksSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.searchText.isEmpty ? "Your books" : "Results")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Text("\(model.filteredBooks.count) \(model.filteredBooks.count == 1 ? "book" : "books")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if model.filteredBooks.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                    ForEach(model.filteredBooks) { book in
                        BookCard(book: book) {
                            withAnimation(.snappy(duration: 0.22)) {
                                openBook(book)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ContinueReadingCard: View {
    let book: Book
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 28) {
                BookCoverView(book: book, compact: true)
                    .frame(width: 86)

                VStack(alignment: .leading, spacing: 8) {
                    Text("CONTINUE READING")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(ReaderColors.moss)

                    Text(book.title)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(ReaderColors.ink)

                    Text(book.libraryMetadataLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    ProgressView(value: book.progress)
                        .progressViewStyle(.linear)
                        .tint(ReaderColors.moss)
                        .frame(maxWidth: 320)
                        .padding(.top, 6)
                }

                Spacer(minLength: 20)

                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ReaderColors.moss)
                    .padding(13)
                    .background(.thinMaterial, in: Circle())
            }
            .padding(22)
            .background(ReaderColors.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(ReaderColors.hairline)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct BookCard: View {
    let book: Book
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                BookCoverView(book: book)

                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ReaderColors.ink)
                        .lineLimit(1)

                    Text(book.author)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(book.libraryMetadataLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    if book.progress > 0 {
                        ProgressView(value: book.progress)
                            .progressViewStyle(.linear)
                            .tint(ReaderColors.moss)
                            .padding(.top, 5)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BookCardButtonStyle())
        .contextMenu {
            Button("Open", action: open)
            Divider()
            Text(book.formatLabel)
        }
    }
}

private struct BookCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

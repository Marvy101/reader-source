import SwiftUI
import UniformTypeIdentifiers

struct QuietLaunchView: View {
    let snapshot: QuietResumeSnapshot
    let goOn: () -> Void
    let openLibrary: () -> Void

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, h:mma"
        return "\(formatter.string(from: snapshot.openedAt)). you stopped here."
            .lowercased()
    }

    var body: some View {
        ZStack {
            QuietReaderColor.paper.ignoresSafeArea()

            VStack(spacing: 28) {
                QuietVoiceText(text: timestamp, size: 15, color: QuietReaderColor.voice)

                Text(snapshot.sentence)
                    .font(QuietReaderTypography.content(size: 23))
                    .tracking(QuietReaderTypography.tracking(for: 23))
                    .foregroundStyle(QuietReaderColor.ink)
                    .lineSpacing(14.95)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                QuietActionWord(
                    title: "go on",
                    size: 15,
                    restingColor: QuietReaderColor.ink,
                    action: goOn
                )
            }
            .frame(maxWidth: 660)

            Button(action: openLibrary) {
                QuietVoiceText(text: "library")
            }
            .buttonStyle(.plain)
            .padding(.leading, 48)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            QuietVoiceText(text: snapshot.book.pagesRemainingLabel)
                .padding(.trailing, 48)
                .padding(.bottom, 38)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}

struct QuietLibraryScreen: View {
    let allBooks: [Book]
    @Binding var bookPickerLibrary: ReaderLibraryOption?
    let addBookToLibrary: (Book, UUID) async throws -> Void
    let books: [Book]
    let isLibraryEmpty: Bool
    let libraries: [ReaderLibraryOption]
    let selectedLibraryID: UUID?
    let openBook: (Book) -> Void
    let search: () -> Void
    let importBooks: () -> Void
    let importDroppedBooks: ([URL]) -> Bool
    let selectLibrary: (UUID?) -> Void
    let browseAllBooks: () -> Void
    let createLibrary: (String) -> Void
    let renameLibrary: (UUID, String) -> Void
    let deleteLibrary: (UUID) -> Void
    let libraryIDForBook: (Book) -> UUID?
    let moveBook: (Book, UUID?) -> Void
    let reorderBook: (Book, Book) -> Void
    let persistBookOrder: () -> Void

    @State private var addButtonHovered = false
    @State private var searchButtonHovered = false
    @State private var isDropTarget = false
    @State private var draggedBookID: UUID?
    private let presentation = QuietLibraryPresentation.preview

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 44, alignment: .top),
        count: 4
    )

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    QuietLibrarySelector(
                        libraries: libraries,
                        selection: selectedLibraryID,
                        select: selectLibrary,
                        create: createLibrary,
                        rename: renameLibrary,
                        delete: deleteLibrary,
                        bookForID: { id in books.first { $0.id == id } },
                        moveBook: moveBook,
                        libraryIDForBook: libraryIDForBook,
                        draggedBookID: $draggedBookID
                    )

                    if let library = libraries.first(where: { $0.id == selectedLibraryID }) {
                        QuietActionWord(title: "add books", size: 13, restingColor: QuietReaderColor.ink) {
                            bookPickerLibrary = library
                        }
                        .accessibilityLabel("Add books to \(library.title)")
                    }

                    if books.isEmpty, !isLibraryEmpty {
                        VStack(spacing: 14) {
                            QuietVoiceText(text: "nothing here yet", size: 15)
                            QuietVoiceText(
                                text: selectedLibraryID == nil
                                    ? "try browsing your full library"
                                    : "choose books from your full library",
                                size: 13
                            )
                            QuietActionWord(
                                title: selectedLibraryID == nil ? "browse all books" : "choose books",
                                size: 13,
                                restingColor: QuietReaderColor.ink,
                                action: {
                                    if let library = libraries.first(where: { $0.id == selectedLibraryID }) {
                                        bookPickerLibrary = library
                                    } else {
                                        browseAllBooks()
                                    }
                                }
                            )
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                            ForEach(books) { book in
                                QuietBookCell(
                                    book: book,
                                    presentation: presentation,
                                    libraries: libraries,
                                    libraryID: libraryIDForBook(book),
                                    open: { openBook(book) },
                                    move: { moveBook(book, $0) },
                                    draggedBookID: $draggedBookID,
                                    insertsAfter: draggedBookID.flatMap { id in
                                        books.firstIndex { $0.id == id }
                                    }.map { source in
                                        source < (books.firstIndex { $0.id == book.id } ?? source)
                                    } ?? false,
                                    persistBookOrder: persistBookOrder,
                                    reorder: { draggedBookID in
                                        guard let draggedBook = books.first(where: {
                                            $0.id == draggedBookID
                                        }) else { return }
                                        reorderBook(draggedBook, book)
                                    }
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: 1_120)
                .padding(.leading, QuietReaderMetric.contentLeftGutter)
                .padding(.trailing, QuietReaderMetric.contentRightGutter)
                .padding(.top, 56)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)

            if isLibraryEmpty {
                VStack(spacing: 12) {
                    QuietVoiceText(
                        text: isDropTarget ? "let go to add it" : "drop a book here",
                        size: 15,
                        color: isDropTarget
                            ? QuietReaderColor.ink
                            : QuietReaderColor.voiceQuiet
                    )

                    HStack(spacing: 5) {
                        QuietVoiceText(text: "or", size: 14)
                        QuietActionWord(
                            title: "choose a file",
                            size: 14,
                            restingColor: QuietReaderColor.ink,
                            action: importBooks
                        )
                    }
                }
                .offset(x: QuietReaderMetric.contentLeftGutter / 2)
                .accessibilityElement(children: .contain)
            }

            Button(action: search) {
                Image(systemName: "magnifyingglass")
                    .font(
                        .system(
                            size: QuietUtilityControl.symbolSize,
                            weight: .regular
                        )
                    )
                    .foregroundStyle(
                        searchButtonHovered
                            ? QuietUtilityControl.activeInk
                            : QuietUtilityControl.restingInk
                    )
                    .frame(
                        width: QuietUtilityControl.size,
                        height: QuietUtilityControl.size
                    )
                    .background(
                        searchButtonHovered
                            ? QuietUtilityControl.hoverBackground
                            : Color.clear,
                        in: RoundedRectangle(
                            cornerRadius: QuietUtilityControl.cornerRadius,
                            style: .continuous
                        )
                    )
            }
            .buttonStyle(.plain)
            .onHover { searchButtonHovered = $0 }
            .help("Search library")
            .accessibilityLabel("Search library")
            .padding(.trailing, QuietReaderMetric.windowHorizontalMargin)
            .padding(.top, QuietReaderMetric.menuTop - 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            Button(action: importBooks) {
                Image(systemName: "plus")
                    .font(
                        .system(
                            size: QuietUtilityControl.symbolSize,
                            weight: .regular
                        )
                    )
                    .foregroundStyle(
                        addButtonHovered
                            ? QuietUtilityControl.activeInk
                            : QuietUtilityControl.restingInk
                    )
                    .frame(
                        width: QuietUtilityControl.size,
                        height: QuietUtilityControl.size
                    )
                    .background(
                        addButtonHovered
                            ? QuietUtilityControl.hoverBackground
                            : Color.clear,
                        in: RoundedRectangle(
                            cornerRadius: QuietUtilityControl.cornerRadius,
                            style: .continuous
                        )
                    )
            }
            .buttonStyle(.plain)
            .onHover { addButtonHovered = $0 }
            .help("Add books")
            .accessibilityLabel("Add books")
            .padding(.trailing, QuietReaderMetric.windowHorizontalMargin)
            .padding(.bottom, QuietReaderMetric.menuAccountBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .background(QuietReaderColor.paper)
        .sheet(item: $bookPickerLibrary) { library in
            QuietLibraryBookPicker(
                books: allBooks,
                library: library,
                libraries: libraries,
                libraryIDForBook: libraryIDForBook,
                addBook: addBookToLibrary
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
            importDroppedBooks(urls)
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.12)) {
                isDropTarget = targeted
            }
        }

    }
}

private struct QuietLibraryBookPicker: View {
    let books: [Book]
    let library: ReaderLibraryOption
    let libraries: [ReaderLibraryOption]
    let libraryIDForBook: (Book) -> UUID?
    let addBook: (Book, UUID) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var visibleBooks: [Book] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter {
            term.isEmpty || $0.title.localizedStandardContains(term)
                || $0.author.localizedStandardContains(term)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("add books to \(library.title)")
                    .font(QuietReaderTypography.appVoice(size: 20))
                Text("Choose from all your books. Books in another folder will move here.")
                    .font(.system(size: 13))
                    .foregroundStyle(QuietReaderColor.voice)
            }
            TextField("Search by title or author", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search books to add")
                .disabled(isSaving)

            ScrollView {
                if visibleBooks.isEmpty {
                    Text(books.isEmpty ? "Import a book to your library first." : "No books match your search.")
                        .foregroundStyle(QuietReaderColor.voice)
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 4), spacing: 24) {
                        ForEach(visibleBooks) { book in
                            bookChoice(book)
                        }
                    }
                    .padding(6)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .accessibilityLabel(errorMessage)
            }
            HStack(spacing: 16) {
                Text("\(selection.count) selected")
                    .foregroundStyle(QuietReaderColor.voice)
                if !selection.isEmpty {
                    Button("Clear") { selection.removeAll() }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(isSaving ? "Adding…" : "Add \(selection.count) \(selection.count == 1 ? "book" : "books")") {
                    saveSelection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || isSaving)
            }
            .font(.system(size: 13))
        }
        .padding(28)
        .frame(width: 740, height: 630)
        .background(QuietReaderColor.paper)
        .interactiveDismissDisabled(isSaving)
    }

    private func bookChoice(_ book: Book) -> some View {
        let alreadyAdded = libraryIDForBook(book) == library.id
        let selected = selection.contains(book.id)
        let previousLibrary = libraries.first { $0.id == libraryIDForBook(book) }
        return Button {
            if selected { selection.remove(book.id) }
            else { selection.insert(book.id) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                BookCoverView(book: book)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selected || alreadyAdded ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(selected ? QuietReaderColor.ink : QuietReaderColor.voice, .white)
                            .padding(8)
                    }
                Text(book.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .frame(height: 32, alignment: .topLeading)
                Text(alreadyAdded ? "already here" : previousLibrary.map { "in \($0.title)" } ?? book.author)
                    .font(.system(size: 11))
                    .foregroundStyle(QuietReaderColor.voice)
                    .lineLimit(1)
            }
            .padding(6)
            .background(selected ? QuietReaderColor.ink.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded || isSaving)
        .opacity(alreadyAdded ? 0.55 : 1)
        .accessibilityLabel("\(book.title)\(alreadyAdded ? ", already in this folder" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func saveSelection() {
        let chosen = books.filter { selection.contains($0.id) }
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            var failures: [String] = []
            for book in chosen {
                do {
                    try await addBook(book, library.id)
                    selection.remove(book.id)
                } catch {
                    failures.append("\(book.title): \(error.localizedDescription)")
                }
            }
            isSaving = false
            if failures.isEmpty {
                dismiss()
            } else {
                errorMessage = "Couldn't add \(failures.count) \(failures.count == 1 ? "book" : "books"). \(failures[0]) Your remaining selection is ready to retry."
            }
        }
    }
}

private struct QuietLibrarySelector: View {
    let libraries: [ReaderLibraryOption]
    let selection: UUID?
    let select: (UUID?) -> Void
    let create: (String) -> Void
    let rename: (UUID, String) -> Void
    let delete: (UUID) -> Void
    let bookForID: (UUID) -> Book?
    let moveBook: (Book, UUID?) -> Void
    let libraryIDForBook: (Book) -> UUID?
    @Binding var draggedBookID: UUID?

    @State private var isCreating = false
    @State private var draftName = ""
    @State private var editingLibraryID: UUID?
    @State private var libraryPendingDeletion: ReaderLibraryOption?
    @State private var addHovered = false
    @State private var targetedLibraryID: UUID?
    @State private var hoveredLibraryID: UUID?
    @State private var allHovered = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                libraryWord(title: "all", id: nil)

                ForEach(libraries) { library in
                    Group {
                        if editingLibraryID == library.id {
                            TextField("library name", text: $draftName)
                                .textFieldStyle(.plain)
                                .font(QuietReaderTypography.appVoice(size: 13))
                                .tracking(QuietReaderTypography.tracking(for: 13))
                                .foregroundStyle(QuietReaderColor.ink)
                                .frame(width: 140, height: 30)
                                .padding(.horizontal, 10)
                                .background(QuietReaderColor.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                                .focused($nameFocused)
                                .onSubmit { commitRename(library.id) }
                                .onExitCommand(perform: cancel)
                                .onAppear { nameFocused = true }
                        } else {
                            libraryWord(title: library.title, id: library.id)
                                .contextMenu {
                                    Button("Rename") { beginRename(library) }
                                    Button("Delete", role: .destructive) {
                                        libraryPendingDeletion = library
                                    }
                                }
                        }
                    }
                        .onDrop(
                            of: [QuietLibraryDrag.type],
                            delegate: QuietLibraryDropDelegate(
                                isTargeted: Binding(
                                    get: { targetedLibraryID == library.id },
                                    set: { targeted in
                                        if targeted { targetedLibraryID = library.id }
                                        else if targetedLibraryID == library.id { targetedLibraryID = nil }
                                    }
                                ),
                                canDrop: {
                                    guard let id = draggedBookID,
                                          let book = bookForID(id) else { return false }
                                    return libraryIDForBook(book) != library.id
                                },
                                perform: {
                                    guard let id = draggedBookID,
                                          let book = bookForID(id) else { return }
                                    moveBook(book, library.id)
#if !os(macOS)
                                    draggedBookID = nil
#endif
                                }
                            )
                        )
                }

                if isCreating {
                    TextField("name this library", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(QuietReaderTypography.appVoice(size: 13))
                        .tracking(QuietReaderTypography.tracking(for: 13))
                        .foregroundStyle(QuietReaderColor.ink)
                        .frame(width: 140, height: 30)
                                .padding(.horizontal, 10)
                                .background(QuietReaderColor.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .onExitCommand(perform: cancel)
                        .onAppear { nameFocused = true }
                        .accessibilityLabel("library name")
                } else {
                    Button {
                        cancel()
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(
                                addHovered
                                    ? QuietReaderColor.ink
                                    : QuietReaderColor.voiceQuiet
                            )
                            .frame(width: 30, height: 30)
                            .background(addHovered ? QuietReaderColor.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { addHovered = $0 }
                    .help("New library")
                    .accessibilityLabel("new library")
                }
            }
        }
        .scrollIndicators(.never)
        .onChange(of: nameFocused) { _, focused in
            if !focused { cancel() }
        }
        .confirmationDialog(
            "delete \(libraryPendingDeletion?.title.lowercased() ?? "this library")?",
            isPresented: Binding(
                get: { libraryPendingDeletion != nil },
                set: { if !$0 { libraryPendingDeletion = nil } }
            )
        ) {
            Button("Delete Library", role: .destructive) {
                if let libraryPendingDeletion {
                    delete(libraryPendingDeletion.id)
                }
                libraryPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                libraryPendingDeletion = nil
            }
        } message: {
            Text("Only empty libraries can be deleted.")
        }
    }

    private func libraryWord(title: String, id: UUID?) -> some View {
        let targeted = id != nil && targetedLibraryID == id
        let selected = selection == id
        let hovered = id == nil ? allHovered : hoveredLibraryID == id
        return Button { select(id) } label: {
            Text(title.lowercased())
                .font(QuietReaderTypography.appVoice(size: 13))
                .tracking(QuietReaderTypography.tracking(for: 13))
                .lineLimit(1)
            .foregroundStyle(selected || targeted || hovered ? QuietReaderColor.ink : QuietReaderColor.voice)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                QuietReaderColor.ink.opacity(targeted ? 0.055 : (hovered ? 0.025 : 0)),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(alignment: .bottom) {
                if targeted {
                    Rectangle()
                        .fill(QuietReaderColor.ink.opacity(0.3))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in
            if id == nil { allHovered = value }
            else { hoveredLibraryID = value ? id : nil }
        }
        .help(targeted ? "Move book to \(title)" : title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func commit() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            cancel()
            return
        }
        create(name)
        draftName = ""
        isCreating = false
    }

    private func beginRename(_ library: ReaderLibraryOption) {
        cancel()
        editingLibraryID = library.id
        draftName = library.title.split(separator: "/").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? library.title
        nameFocused = true
    }

    private func commitRename(_ libraryID: UUID) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            cancel()
            return
        }
        rename(libraryID, name)
        editingLibraryID = nil
        draftName = ""
    }

    private func cancel() {
        draftName = ""
        isCreating = false
        editingLibraryID = nil
    }
}

private struct QuietBookCell: View {
    let book: Book
    let presentation: QuietLibraryPresentation
    let libraries: [ReaderLibraryOption]
    let libraryID: UUID?
    let open: () -> Void
    let move: (UUID?) -> Void
    @Binding var draggedBookID: UUID?
    let insertsAfter: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let persistBookOrder: () -> Void
    let reorder: (UUID) -> Void

    @State private var hovered = false
    @State private var isReorderTarget = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottom) {
                    bookArtwork
                        .opacity(draggedBookID == book.id ? 0 : 1)
                        .animation(nil, value: draggedBookID)
#if os(macOS)
                        .overlay {
                            LibraryBookDragSource(
                                bookID: book.id,
                                image: { size in
                                    let renderer = ImageRenderer(
                                        content: bookArtwork.frame(width: size.width, height: size.height)
                                    )
                                    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
                                    return renderer.nsImage
                                },
                                open: open,
                                began: { draggedBookID = book.id },
                                ended: {
                                    if draggedBookID == book.id { draggedBookID = nil }
                                    hovered = false
                                }
                            )
                            .accessibilityHidden(true)
                        }
#endif
                    if presentation == .shelves {
                        QuietLibraryShelf()
                            .frame(height: 10)
                            .padding(.horizontal, -22)
                            .offset(y: 8)
                            .allowsHitTesting(false)
                    }
                }
                .offset(x: !reduceMotion && isReorderTarget ? (insertsAfter ? -7 : 7) : 0)

                VStack(alignment: .leading, spacing: 3) {
                    QuietContentText(text: book.title, size: 14)
                        .lineLimit(2)
                    QuietVoiceText(text: book.pagesRemainingLabel, size: 12)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : QuietReaderMotion.libraryReorder, value: isReorderTarget)
        .overlay(alignment: insertsAfter ? .trailing : .leading) {
            if isReorderTarget {
                Capsule()
                    .fill(QuietReaderColor.ink.opacity(0.6))
                    .frame(width: 2)
                    .padding(.vertical, 4)
                    .offset(x: insertsAfter ? 20 : -20)
                    .allowsHitTesting(false)
            }
        }
#if !os(macOS)
        .onDrag {
            hovered = false
            draggedBookID = book.id
            return QuietLibraryDrag.provider(for: book.id)
        } preview: {
            QuietPhysicalBook(
                book: book,
                presentation: presentation == .flat ? .shelves : presentation,
                lifted: !reduceMotion
            )
            .frame(width: 152)
            .padding(20)
        }
#endif
        .onDrop(
            of: [QuietLibraryDrag.type],
            delegate: QuietLibraryDropDelegate(
                isTargeted: $isReorderTarget,
                canDrop: { draggedBookID != nil && draggedBookID != book.id },
                perform: {
                    guard let id = draggedBookID else { return }
                    withAnimation(reduceMotion ? nil : QuietReaderMotion.libraryReorder) {
                        reorder(id)
                    }
#if !os(macOS)
                    draggedBookID = nil
#endif
                    persistBookOrder()
                }
            )
        )
        .onHover { value in
            withAnimation(reduceMotion ? nil : QuietReaderMotion.libraryReorder) {
                hovered = value
            }
        }
        .contextMenu {
            Button("Open", action: open)

            if !libraries.isEmpty {
                Divider()
                Menu("Move to Library") {
                    Button("No Library") { move(nil) }
                        .disabled(libraryID == nil)

                    Divider()

                    ForEach(libraries) { library in
                        Button(library.title) { move(library.id) }
                            .disabled(libraryID == library.id)
                    }
                }
            }
        }
        .accessibilityLabel("\(book.title), \(book.pagesRemainingLabel)")
    }

    @ViewBuilder
    private var bookArtwork: some View {
        if presentation == .flat {
            BookCoverView(book: book)
        } else {
            QuietPhysicalBook(
                book: book,
                presentation: presentation,
                lifted: false
            )
        }
    }

}

// Shelves are the chosen presentation; debug overrides keep comparison builds available.
enum QuietLibraryPresentation: String {
    case flat, shelves, tabletop

    static var preview: Self {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--quiet-reader-library-style"),
           arguments.indices.contains(index + 1) {
            return Self(rawValue: arguments[index + 1]) ?? .shelves
        }
        if let name = Bundle.main.object(forInfoDictionaryKey: "ReaderLibraryPresentation") as? String {
            return Self(rawValue: name) ?? .shelves
        }
#endif
        return .shelves
    }
}

private struct QuietPhysicalBook: View {
    let book: Book
    let presentation: QuietLibraryPresentation
    var lifted = false

    private var thickness: CGFloat {
        let pages = book.totalPageCount ?? 240
        return min(11, max(1.5, CGFloat(pages) / 65))
    }

    var body: some View {
        GeometryReader { geometry in
            let depth = thickness
            let width = geometry.size.width - depth - 4
            let height = geometry.size.height - depth - 4
            ZStack(alignment: .topLeading) {
                // Back board and paper are separate surfaces beneath the real cover.
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: (book.totalPageCount ?? 240) > 8 ? 0.3 : 0.7))
                    .frame(width: width, height: height)
                    .offset(x: depth, y: depth)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: 0.9, green: 0.875, blue: 0.81))
                    .frame(width: width - 3, height: height - 3)
                    .offset(x: depth + 1, y: depth)
                ForEach(0..<5, id: \.self) { layer in
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(white: layer.isMultiple(of: 2) ? 0.98 : 0.68).opacity(0.65), lineWidth: 0.5)
                        .frame(width: width - 3, height: height - 3)
                        .offset(x: depth * CGFloat(layer + 1) / 6, y: depth * CGFloat(layer + 1) / 6)
                }
                BookCoverView(book: book, castsShadow: false)
                    .frame(width: width, height: height)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 2) {
                            Rectangle().fill(.black.opacity(0.18)).frame(width: 2)
                            Rectangle().fill(.white.opacity(0.18)).frame(width: 1)
                            Rectangle().fill(.black.opacity(0.12)).frame(width: 1)
                        }
                        .padding(.leading, 3)
                        .padding(.vertical, 2)
                    }
            }
            .compositingGroup()
            .rotation3DEffect(
                .degrees(presentation == .tabletop ? (lifted ? 27 : 18) : (lifted ? -6 : -2)),
                axis: (x: presentation == .tabletop ? 1 : 0, y: -0.5, z: 0),
                perspective: 0.35
            )
            .rotationEffect(.degrees(lifted ? -1.5 : 0))
            .shadow(
                color: .black.opacity(lifted ? 0.2 : (presentation == .tabletop ? 0.17 : 0.13)),
                radius: lifted ? 15 : (presentation == .tabletop ? 10 : 7),
                x: presentation == .tabletop ? 10 : 2,
                y: lifted ? 23 : (presentation == .tabletop ? 15 : 5)
            )
            .offset(y: lifted ? -10 : 0)
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct QuietLibraryShelf: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(red: 0.985, green: 0.98, blue: 0.966)).frame(height: 3)
            Rectangle().fill(Color(red: 0.925, green: 0.918, blue: 0.9)).frame(height: 6)
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 9)
        .accessibilityHidden(true)
    }
}

// The custom type keeps text/file imports out of book-move targets. A standard
// text representation also lets the native dragging system lift the item.
enum QuietLibraryDrag {
    static let type = UTType(exportedAs: "com.example.reader.library-book", conformingTo: .data)

    static func provider(for bookID: UUID) -> NSItemProvider {
        let provider = NSItemProvider(object: bookID.uuidString as NSString)
        let payload = Data(bookID.uuidString.utf8)
        // SwiftUI bridges this provider through the native drag pasteboard.
        // Do not restrict its representation to an in-process-only transfer.
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .all
        ) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }
}

private struct QuietLibraryDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let canDrop: () -> Bool
    let perform: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [QuietLibraryDrag.type]) && canDrop()
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info) else { return false }
        // Commit only on release. Cancelling or leaving the window cannot reorder books.
        perform()
        return true
    }
}

struct QuietKeptScreen: View {
    let items: [QuietHighlightItem]
    let open: (QuietHighlightItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 44) {
                ForEach(items) { item in
                    Button { open(item) } label: {
                        HStack(alignment: .top, spacing: 22) {
                            Rectangle()
                                .fill(item.annotation.highlightColor.swiftUIColor)
                                .frame(width: 5)

                            VStack(alignment: .leading, spacing: 9) {
                                Text(item.annotation.selectedText)
                                    .font(QuietReaderTypography.content(size: 19))
                                    .tracking(QuietReaderTypography.tracking(for: 19))
                                    .foregroundStyle(QuietReaderColor.inkSecondary)
                                    .lineSpacing(11.4)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let note = item.annotation.note {
                                    Text(note)
                                        .font(QuietReaderTypography.content(size: 15))
                                        .tracking(QuietReaderTypography.tracking(for: 15))
                                        .foregroundStyle(QuietReaderColor.inkSecondary.opacity(0.72))
                                        .lineSpacing(7)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                QuietVoiceText(
                                    text: "\(item.book.title) · \(item.annotation.note == nil ? "kept" : "with a note")",
                                    size: 12
                                )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(item.annotation.selectedText), \(item.annotation.highlightColor.displayName) highlight, \(item.book.title)"
                    )
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.leading, QuietReaderMetric.contentLeftGutter)
            .padding(.trailing, QuietReaderMetric.contentRightGutter)
            .padding(.top, 100)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

struct QuietAIListScreen: View {
    let conversations: [ReaderConversation]
    let open: (ReaderConversation) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 44) {
                ForEach(conversations) { conversation in
                    Button { open(conversation) } label: {
                        HStack(alignment: .top, spacing: 22) {
                            Rectangle()
                                .fill(QuietReaderColor.hairline)
                                .frame(width: 5)

                            VStack(alignment: .leading, spacing: 10) {
                                QuietVoiceText(
                                    text: conversation.question,
                                    size: 15,
                                    color: QuietReaderColor.voice
                                )
                                Text(conversation.answer)
                                    .font(QuietReaderTypography.content(size: 19))
                                    .tracking(QuietReaderTypography.tracking(for: 19))
                                    .foregroundStyle(QuietReaderColor.inkSecondary)
                                    .lineSpacing(11.4)
                                    .fixedSize(horizontal: false, vertical: true)
                                QuietVoiceText(
                                    text: "\(conversation.publicationTitle) · \(conversation.createdAt.formatted(.relative(presentation: .named)))",
                                    size: 12
                                )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.leading, QuietReaderMetric.contentLeftGutter)
            .padding(.trailing, QuietReaderMetric.contentRightGutter)
            .padding(.top, 100)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

struct QuietAskScreen: View {
    let conversation: ReaderConversation
    let backToPage: () -> Void
    let otherReadings: () -> Void
    let lookUp: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 34) {
                QuietVoiceText(
                    text: conversation.question.lowercased(),
                    size: 15,
                    color: QuietReaderColor.voice
                )
                .multilineTextAlignment(.center)

                Text(conversation.answer)
                    .font(QuietReaderTypography.content(size: 21))
                    .tracking(QuietReaderTypography.tracking(for: 21))
                    .foregroundStyle(QuietReaderColor.ink)
                    .lineSpacing(15.12)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 28) {
                    QuietActionWord(
                        title: "the other failed readings",
                        action: otherReadings
                    )
                    QuietActionWord(title: "look this up", action: lookUp)
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 48)

            Button(action: backToPage) {
                QuietVoiceText(
                    text: "back to the page",
                    color: QuietReaderColor.voiceQuiet
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, 48)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuietReaderColor.paper)
    }
}

struct QuietSearchScreen: View {
    @Binding var query: String
    let results: [QuietSearchResult]
    let catalogResults: [ReaderCatalogResult]
    let isCatalogLoading: Bool
    let open: (QuietSearchResult) -> Void
    let catalogAction: (ReaderCatalogResult) -> Void
    let escape: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 52) {
                TextField("type", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 34, weight: .light))
                    .tracking(-0.34)
                    .foregroundStyle(QuietReaderColor.ink)
                    .focused($focused)
                    .onSubmit { focused = true }

                VStack(alignment: .leading, spacing: 48) {
                    if !results.isEmpty {
                        searchSectionTitle("in your reading")
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ForEach(results) { result in
                                Button { open(result) } label: {
                                    HStack(alignment: .top, spacing: 20) {
                                        Rectangle()
                                            .fill(
                                                result.coverStyle?.accentColor
                                                    ?? QuietReaderColor.hairline
                                            )
                                            .frame(width: 4, height: 38)

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(emphasized(result.text))
                                                .font(QuietReaderTypography.content(size: 17))
                                                .tracking(
                                                    QuietReaderTypography.tracking(for: 17)
                                                )
                                                .foregroundStyle(
                                                    QuietReaderColor.inkSecondary
                                                )
                                                .lineSpacing(9.35)
                                                .fixedSize(
                                                    horizontal: false,
                                                    vertical: true
                                                )
                                            QuietVoiceText(
                                                text: result.sourceLine,
                                                size: 12
                                            )
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if isCatalogLoading || !catalogResults.isEmpty {
                        searchSectionTitle("the catalog")
                        if isCatalogLoading, catalogResults.isEmpty {
                            QuietVoiceText(
                                text: "looking through the shelves",
                                color: QuietReaderColor.voiceFaint
                            )
                        } else {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(catalogResults) { result in
                                    catalogRow(result)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(.leading, QuietReaderMetric.contentLeftGutter)
            .padding(.trailing, QuietReaderMetric.contentRightGutter)
            .padding(.top, 96)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .onAppear { focused = true }
        .onExitCommand(perform: escape)
        .overlay(alignment: .bottomTrailing) {
            Button(action: escape) {
                QuietVoiceText(text: "esc", color: QuietReaderColor.voiceFaint)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 48)
            .padding(.bottom, 34)
        }
    }

    private func searchSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(QuietReaderColor.voiceFaint)
    }

    private func catalogRow(_ result: ReaderCatalogResult) -> some View {
        HStack(alignment: .top, spacing: 18) {
            AsyncImage(url: result.coverUrl) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(QuietReaderColor.hairline)
            }
            .frame(width: 42, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(result.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(QuietReaderColor.ink)
                    .lineLimit(2)
                QuietVoiceText(text: result.byline, size: 12)
                if !result.metadataLine.isEmpty {
                    QuietVoiceText(
                        text: result.metadataLine,
                        size: 11,
                        color: QuietReaderColor.voiceFaint
                    )
                }
            }

            Spacer(minLength: 20)

            Button(result.availability.actionLabel) {
                catalogAction(result)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(QuietReaderColor.voice)
            .padding(.top, 2)
        }
        .contentShape(Rectangle())
    }

    private func emphasized(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }

        var searchStart = text.startIndex
        while
            searchStart < text.endIndex,
            let range = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
            )
        {
            if let attributedRange = Range(range, in: attributed) {
                attributed[attributedRange].font = .system(size: 17, weight: .semibold)
            }
            searchStart = range.upperBound
        }
        return attributed
    }
}

struct QuietTypeScreen: View {
    @Binding var preferences: QuietReadingPreferences
    let back: () -> Void

    var body: some View {
        ZStack {
            preferences.theme.background.ignoresSafeArea()

            Button {
                preferences.changeSize(by: -1)
            } label: {
                Text("smaller")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(preferences.theme.ink.opacity(0.78))
            }
            .buttonStyle(.plain)
            .padding(.leading, 88)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Button {
                preferences.changeSize(by: 1)
            } label: {
                Text("larger")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(preferences.theme.ink.opacity(0.78))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 88)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            VStack(spacing: 26) {
                Text("But by dint of much and earnest contemplation, and oft repeated ponderings, you at last come to the conclusion.")
                    .font(
                        QuietReaderTypography.reading(
                            size: CGFloat(preferences.size),
                            serif: preferences.serif
                        )
                    )
                    .foregroundStyle(preferences.theme.ink)
                    .lineSpacing(CGFloat(preferences.size) * 0.8)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 22) {
                    fontWord("sans", serif: false)
                    fontWord("serif", serif: true)
                }

                HStack(spacing: 12) {
                    ForEach(QuietReadingTheme.allCases, id: \.self) { theme in
                        Button { preferences.theme = theme } label: {
                            Circle()
                                .fill(theme.background)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    Circle().stroke(
                                        preferences.theme == theme
                                            ? preferences.theme.ink.opacity(0.55)
                                            : Color.black.opacity(theme == .white ? 0.18 : 0),
                                        lineWidth: 1
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(theme.rawValue) reading theme")
                    }
                }
                .padding(.top, 4)
            }
            .frame(width: 520)

            Button(action: back) {
                QuietVoiceText(text: "back to the page", color: QuietReaderColor.voiceFaint)
            }
            .buttonStyle(.plain)
            .padding(.leading, 48)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func fontWord(_ title: String, serif: Bool) -> some View {
        Button { preferences.serif = serif } label: {
            Text(title)
                .font(
                    serif
                        ? .custom("Georgia", size: 14).weight(.light)
                        : .system(size: 14, weight: .light)
                )
                .foregroundStyle(preferences.theme.ink.opacity(0.62))
        }
        .buttonStyle(.plain)
    }
}

struct QuietAccountScreen: View {
    @Bindable var account: ReaderAccountModel
    let books: [Book]
    let syncMessage: String
    let openLibrary: () -> Void
    let openType: () -> Void
    let signOut: () -> Void

    @FocusState private var focused: Bool

    private var pagesRead: Int {
        books.reduce(0) { partial, book in
            partial + Int(Double(book.totalPageCount ?? 0) * book.progress)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 26) {
                QuietAccountMarkView(mark: account.accountMark, size: 96)
                VStack(spacing: 7) {
                    QuietContentText(text: account.displayName, size: 21, color: QuietReaderColor.ink)
                    QuietVoiceText(text: account.email ?? "")
                }
                VStack(spacing: 8) {
                    QuietVoiceText(text: "\(books.count) books · \(pagesRead.formatted()) pages read this year", color: QuietReaderColor.voice)
                    QuietVoiceText(text: syncMessage, color: QuietReaderColor.voice)
                }
                HStack(spacing: 26) {
                    QuietActionWord(title: "type", action: openType)
                    QuietActionWord(title: "sign out", action: signOut)
                }
            }

            Button(action: openLibrary) {
                QuietVoiceText(text: "library")
            }
            .buttonStyle(.plain)
            .padding(.leading, QuietReaderMetric.windowHorizontalMargin)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onExitCommand(perform: openLibrary)
    }
}

extension BookCoverStyle {
    var accentColor: Color {
        switch self {
        case .forest: Color(red: 0.16, green: 0.27, blue: 0.21)
        case .night: Color(red: 0.09, green: 0.11, blue: 0.16)
        case .parchment: Color(red: 0.64, green: 0.53, blue: 0.35)
        case .clay: Color(red: 0.57, green: 0.28, blue: 0.20)
        case .sea: Color(red: 0.20, green: 0.37, blue: 0.43)
        }
    }
}

extension Book {
    var coverAccentColor: Color { coverStyle.accentColor }
}

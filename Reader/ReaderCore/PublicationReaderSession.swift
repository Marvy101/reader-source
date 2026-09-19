import Foundation
import Observation

@MainActor
@Observable
final class PublicationReaderSession {
    let book: Book
    let backend: ReadingBackend
    let textIndex: ReaderTextIndex

    var searchQuery = ""
    var searchResults: [ReaderSearchResult] = []
    var activeSearchResultIndex: Int?
    var searchResultsAreTruncated = false
    var annotations: [ReaderAnnotation] = []
    var textScale = 1.0
    var statusMessage: String?
    var resourceIndex: Int
    var selectedSectionID: String?
    var onProgressChanged: ((Double) -> Void)?
    var onReadingStateChanged: (() -> Void)?
    var onAnnotationsChanged: ((ReaderAnnotation) -> Void)?

    private let store: ReaderLibraryStore?
    private let preparedSearchIndex: Task<ReaderTextIndex, Never>
    private var lastPersistedLocator: ReaderLocator?
    private var hasRecordedOpen = false
    private var pendingScale: Double?
    private var scalePersistenceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(book: Book, store: ReaderLibraryStore? = nil) throws {
        guard let reference = book.publication else {
            throw PublicationImportError.unsupportedFormat
        }

        self.book = book
        self.store = store
        let resolvedBackend: ReadingBackend
        switch reference.format {
        case .pdf:
            resolvedBackend = .pdf(
                try PDFKitReadingAdapter(reference: reference)
            )
        case .epub, .plainText:
            resolvedBackend = .web(
                try WebKitReadingAdapter(reference: reference)
            )
        }
        backend = resolvedBackend
        let resolvedTextIndex = ReaderTextIndex(
            publicationFingerprint: reference.fingerprint,
            chunks: try resolvedBackend.adapter.textChunks()
        )
        textIndex = resolvedTextIndex
        preparedSearchIndex = Task.detached(priority: .utility) {
            resolvedTextIndex.preparedForSearch()
        }
        resourceIndex = resolvedBackend.adapter.currentResourceIndex
        let storedState = try store?.loadReadingState(publicationID: book.id)
        annotations = try store?.loadAnnotations(publicationID: book.id) ?? []
        let storedPreferences = try store?.loadDevicePreferences(publicationID: book.id)
        textScale = storedPreferences?.scale ?? 1
        lastPersistedLocator = storedState?.locator

        resolvedBackend.adapter.onResourceIndexChanged = { [weak self] index in
            self?.resourceIndex = index
        }
        resolvedBackend.adapter.onScaleChanged = { [weak self] scale in
            self?.scheduleScalePersistence(scale)
        }
        resolvedBackend.adapter.display(annotations: annotations)
        if storedPreferences != nil {
            resolvedBackend.adapter.setTextScale(textScale)
        }
        if let locator = storedState?.locator {
            resolvedBackend.adapter.navigate(to: locator)
            resourceIndex = resolvedBackend.adapter.currentResourceIndex
        }
    }

    var adapter: any ReadingAdapter {
        backend.adapter
    }

    var capabilities: ReadingCapabilities {
        adapter.capabilities
    }

    var sections: [ReaderSection] {
        adapter.sections
    }

    var usesDiscretePageControls: Bool {
        adapter.format == .pdf
    }

    var supportsInlineRewrite: Bool {
        true
    }

    func beginInlineRewrite(_ selection: ReaderSelection) async -> Bool {
        switch backend {
        case .pdf(let adapter): adapter.beginInlineRewrite(selection)
        case .web(let adapter): await adapter.beginInlineRewrite(selection)
        }
    }

    func showInlineRewrite(_ text: String) {
        switch backend {
        case .pdf(let adapter): adapter.showInlineRewrite(text)
        case .web(let adapter): adapter.showInlineRewrite(text)
        }
    }

    func showInlineRewriteFailure(_ message: String) {
        switch backend {
        case .pdf(let adapter): adapter.showInlineRewriteFailure(message)
        case .web(let adapter): adapter.showInlineRewriteFailure(message)
        }
    }

    func restartInlineRewriteLoading() {
        switch backend {
        case .pdf(let adapter): adapter.restartInlineRewriteLoading()
        case .web(let adapter): adapter.restartInlineRewriteLoading()
        }
    }

    func captureInlineRewriteAction() async -> ReaderInlineRewriteAction? {
        switch backend {
        case .pdf(let adapter): adapter.captureInlineRewriteAction()
        case .web(let adapter): await adapter.captureInlineRewriteAction()
        }
    }

    func dismissInlineRewrite() {
        switch backend {
        case .pdf(let adapter): adapter.dismissInlineRewrite()
        case .web(let adapter): adapter.dismissInlineRewrite()
        }
    }

    var locationLabel: String? {
        guard adapter.format == .pdf else { return nil }
        return "Page \(resourceIndex + 1) of \(adapter.resourceCount)"
    }

    var canMoveBackward: Bool {
        resourceIndex > 0
    }

    var canMoveForward: Bool {
        resourceIndex < adapter.resourceCount - 1
    }

    func bookKnowledgeSnapshot() -> ReaderBookKnowledgeSnapshot? {
        let chunks = textIndex.chunks.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !chunks.isEmpty, let reference = book.publication else { return nil }
        let normalizedChunks = chunks.enumerated().flatMap { sourceIndex, chunk in
            Self.knowledgeSlices(
                chunk: chunk,
                sourceIndex: sourceIndex,
                sourceCount: chunks.count
            )
        }
        return ReaderBookKnowledgeSnapshot(
            publicationID: book.id,
            title: book.title,
            author: book.author,
            format: adapter.format,
            fingerprint: reference.fingerprint,
            currentProgression: min(max(book.progress, 0), 1),
            currentPageNumber: book.totalPageCount.map { total in
                min(max(Int(book.progress * Double(total)) + 1, 1), total)
            },
            chunks: normalizedChunks.enumerated().map { index, chunk in
                ReaderBookKnowledgeSnapshot.Chunk(
                    ordinal: index,
                    resourceId: chunk.resourceID,
                    resourceTitle: chunk.title,
                    text: chunk.text,
                    positionStart: chunk.positionStart,
                    positionEnd: chunk.positionEnd,
                    progressionStart: chunk.progressionStart,
                    progressionEnd: chunk.progressionEnd
                )
            },
            annotations: annotations.map { annotation in
                ReaderBookKnowledgeSnapshot.Annotation(
                    id: annotation.id,
                    selectedText: annotation.selectedText,
                    note: annotation.note,
                    resourceId: annotation.locator.resourceID,
                    position: annotation.locator.position,
                    progression: annotation.locator.progression,
                    locator: annotation.locator,
                    createdAt: annotation.createdAt
                )
            }
        )
    }

    private struct KnowledgeSlice {
        let resourceID: String
        let title: String?
        let text: String
        let positionStart: Int
        let positionEnd: Int
        let progressionStart: Double
        let progressionEnd: Double
    }

    private static func knowledgeSlices(
        chunk: PublicationTextChunk,
        sourceIndex: Int,
        sourceCount: Int,
        maximumCharacters: Int = 6_000,
        overlap: Int = 250
    ) -> [KnowledgeSlice] {
        let sourceLength = chunk.text.count
        guard sourceLength > 0 else { return [] }
        let denominator = Double(max(sourceCount, 1))
        var slices: [KnowledgeSlice] = []
        var start = 0

        while start < sourceLength {
            var end = min(start + maximumCharacters, sourceLength)
            if end < sourceLength {
                let candidateStart = chunk.text.index(
                    chunk.text.startIndex,
                    offsetBy: start
                )
                let candidateEnd = chunk.text.index(
                    chunk.text.startIndex,
                    offsetBy: end
                )
                let window = chunk.text[candidateStart..<candidateEnd]
                if let boundary = window.lastIndex(where: { $0.isWhitespace }) {
                    let boundaryOffset = chunk.text.distance(
                        from: chunk.text.startIndex,
                        to: boundary
                    )
                    if boundaryOffset > start + maximumCharacters / 2 {
                        end = boundaryOffset
                    }
                }
            }
            let lower = chunk.text.index(chunk.text.startIndex, offsetBy: start)
            let upper = chunk.text.index(chunk.text.startIndex, offsetBy: end)
            let text = String(chunk.text[lower..<upper])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let startProgress = (
                    Double(sourceIndex) + Double(start) / Double(sourceLength)
                ) / denominator
                let endProgress = (
                    Double(sourceIndex) + Double(end) / Double(sourceLength)
                ) / denominator
                slices.append(
                    KnowledgeSlice(
                        resourceID: chunk.resourceID,
                        title: chunk.title,
                        text: text,
                        positionStart: start,
                        positionEnd: end,
                        progressionStart: min(max(startProgress, 0), 1),
                        progressionEnd: min(max(endProgress, 0), 1)
                    )
                )
            }
            guard end < sourceLength else { break }
            start = max(end - overlap, start + 1)
        }
        return slices
    }

    func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            resetSearchResults()
            return
        }

        let maximumVisibleResults = 5_000
        let matches = textIndex.search(query, limit: maximumVisibleResults + 1)
        applySearchResults(
            matches,
            maximumVisibleResults: maximumVisibleResults,
            nearestTo: nil
        )
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            resetSearchResults()
            return
        }

        let preparedSearchIndex = preparedSearchIndex
        let maximumVisibleResults = 5_000
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                let index = await preparedSearchIndex.value
                guard !Task.isCancelled else { return [ReaderSearchResult]() }
                return index.search(query, limit: maximumVisibleResults + 1)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            let currentLocator = await self.adapter.currentLocator()
            guard
                !Task.isCancelled,
                self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            self.applySearchResults(
                matches,
                maximumVisibleResults: maximumVisibleResults,
                nearestTo: currentLocator
            )
        }
    }

    private func applySearchResults(
        _ matches: [ReaderSearchResult],
        maximumVisibleResults: Int,
        nearestTo currentLocator: ReaderLocator?
    ) {
        searchResultsAreTruncated = matches.count > maximumVisibleResults
        searchResults = Array(matches.prefix(maximumVisibleResults))
        activeSearchResultIndex = preferredInitialSearchResultIndex(
            in: searchResults,
            nearestTo: currentLocator
        )
        displaySearchResultsAndNavigate()
        statusMessage = searchResults.isEmpty ? "No matches." : nil
    }

    func preferredInitialSearchResultIndex(
        in results: [ReaderSearchResult],
        nearestTo currentLocator: ReaderLocator?
    ) -> Int? {
        guard !results.isEmpty else { return nil }
        guard let currentLocator else { return 0 }

        let resourceOrdinals = Dictionary(
            uniqueKeysWithValues: textIndex.chunks.enumerated().map {
                ($0.element.resourceID, $0.offset)
            }
        )
        guard let currentOrdinal = resourceOrdinals[currentLocator.resourceID] else {
            return 0
        }

        return results.firstIndex { result in
            guard let resultOrdinal = resourceOrdinals[result.locator.resourceID] else {
                return false
            }
            if resultOrdinal != currentOrdinal {
                return resultOrdinal > currentOrdinal
            }
            if adapter.format == .pdf {
                return true
            }
            return result.locator.position >= currentLocator.position
        } ?? 0
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        resetSearchResults()
    }

    func moveSearchResult(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        let current = activeSearchResultIndex ?? 0
        activeSearchResultIndex = (current + offset + searchResults.count) % searchResults.count
        adapter.activateSearchResult(at: activeSearchResultIndex)
        navigateToActiveSearchResult()
    }

    var searchResultLabel: String {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        guard let activeSearchResultIndex, !searchResults.isEmpty else {
            return "no matches"
        }
        let suffix = searchResultsAreTruncated ? "+" : ""
        return "\(activeSearchResultIndex + 1) of \(searchResults.count)\(suffix)"
    }

    private func resetSearchResults() {
        searchResults = []
        activeSearchResultIndex = nil
        searchResultsAreTruncated = false
        statusMessage = nil
        adapter.display(searchResults: [], activeIndex: nil)
    }

    private func displaySearchResultsAndNavigate() {
        adapter.display(
            searchResults: searchResults,
            activeIndex: activeSearchResultIndex
        )
        navigateToActiveSearchResult()
    }

    private func navigateToActiveSearchResult() {
        guard
            let activeSearchResultIndex,
            searchResults.indices.contains(activeSearchResultIndex)
        else { return }
        adapter.navigate(
            toSearchResult: searchResults[activeSearchResultIndex].locator
        )
    }

    func navigate(to result: ReaderSearchResult) {
        adapter.navigate(to: result.locator)
    }

    func navigate(to section: ReaderSection) {
        selectedSectionID = section.id
        adapter.navigate(to: section)
    }

    func moveResource(by offset: Int) {
        adapter.moveResource(by: offset)
    }

    func createHighlightFromSelection() async {
        guard let selection = await adapter.captureSelection() else {
            statusMessage = "Select text in the book first."
            return
        }

        createHighlight(selection)
    }

    func captureSelection() async -> ReaderSelection? {
        await adapter.captureSelection()
    }

    @discardableResult
    func createHighlight(
        _ selection: ReaderSelection,
        note: String? = nil,
        color: ReaderHighlightColor? = nil
    ) -> ReaderAnnotation? {
        let normalizedNote = note?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let existingIndex = annotations.firstIndex {
            $0.publicationFingerprint == adapter.fingerprint
                && $0.locator == selection.locator
                && $0.selectedText == selection.selectedText
        }
        let existing = existingIndex.map { annotations[$0] }
        let annotation = ReaderAnnotation(
            id: existing?.id ?? UUID(),
            publicationFingerprint: adapter.fingerprint,
            locator: selection.locator,
            selectedText: selection.selectedText,
            note: normalizedNote ?? existing?.note,
            notePlacement: existing?.notePlacement,
            highlightColor: color ?? existing?.highlightColor ?? .lemon,
            createdAt: existing?.createdAt ?? .now,
            updatedAt: .now
        )
        do {
            try store?.saveAnnotation(annotation, publicationID: book.id)
        } catch {
            statusMessage = "Reader could not save this highlight."
            return nil
        }
        if let existingIndex {
            annotations[existingIndex] = annotation
        } else {
            annotations.append(annotation)
        }
        adapter.display(annotations: annotations)
        statusMessage = normalizedNote == nil
            ? "Highlighted “\(selection.selectedText.prefix(54))”"
            : "Saved note on “\(selection.selectedText.prefix(54))”"
        onAnnotationsChanged?(annotation)
        return annotation
    }

    func updateHighlightColor(id: UUID, color: ReaderHighlightColor) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let existing = annotations[index]
        let updated = ReaderAnnotation(
            id: existing.id,
            publicationFingerprint: existing.publicationFingerprint,
            locator: existing.locator,
            selectedText: existing.selectedText,
            note: existing.note,
            notePlacement: existing.notePlacement,
            highlightColor: color,
            createdAt: existing.createdAt,
            updatedAt: .now
        )
        do {
            try store?.saveAnnotation(updated, publicationID: book.id)
        } catch {
            statusMessage = "Reader could not change this highlight."
            return
        }
        annotations[index] = updated
        adapter.display(annotations: annotations)
        onAnnotationsChanged?(updated)
    }

    func updateNote(id: UUID, note: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let existing = annotations[index]
        let normalized = note
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let updated = ReaderAnnotation(
            id: existing.id,
            publicationFingerprint: existing.publicationFingerprint,
            locator: existing.locator,
            selectedText: existing.selectedText,
            note: normalized,
            notePlacement: existing.notePlacement,
            highlightColor: existing.highlightColor,
            createdAt: existing.createdAt,
            updatedAt: .now
        )
        do {
            try store?.saveAnnotation(updated, publicationID: book.id)
        } catch {
            statusMessage = "Reader could not save this note."
            return
        }
        annotations[index] = updated
        adapter.display(annotations: annotations)
        statusMessage = normalized == nil ? "Removed note." : "Saved note."
        onAnnotationsChanged?(updated)
    }

    func updateNotePlacement(id: UUID, placement: ReaderNotePlacement) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let existing = annotations[index]
        let updated = ReaderAnnotation(
            id: existing.id,
            publicationFingerprint: existing.publicationFingerprint,
            locator: existing.locator,
            selectedText: existing.selectedText,
            note: existing.note,
            notePlacement: placement,
            highlightColor: existing.highlightColor,
            createdAt: existing.createdAt,
            updatedAt: existing.updatedAt
        )
        do {
            try store?.saveAnnotation(updated, publicationID: book.id)
        } catch {
            statusMessage = "Reader could not move this note."
            adapter.display(annotations: annotations)
            return
        }
        annotations[index] = updated
    }

    func reloadAnnotations() {
        guard let store, let updated = try? store.loadAnnotations(publicationID: book.id) else {
            return
        }
        annotations = updated
        adapter.display(annotations: annotations)
    }

    func captureHighlightQuestion() async -> HighlightQuestionDraft? {
        guard let selection = await adapter.captureSelection() else {
            statusMessage = "Select text in the book first."
            return nil
        }
        return highlightQuestionDraft(for: selection)
    }

    func highlightQuestionDraft(
        for selection: ReaderSelection
    ) -> HighlightQuestionDraft? {
        guard selection.selectedText.count <= 8_000 else {
            statusMessage = "Ask about a selection of 8,000 characters or fewer."
            return nil
        }

        return HighlightQuestionDraft(
            publicationID: book.id,
            publicationTitle: book.title,
            publicationAuthor: book.author,
            publicationFormat: adapter.format,
            selection: selection,
            context: textIndex.context(around: selection)
        )
    }

    func navigate(to locator: ReaderLocator) {
        adapter.navigate(to: locator)
    }

    func changeTextScale(by delta: Double) {
        let limits = adapter.format == .pdf
            ? 0.65...2.5
            : 0.75...2.5
        textScale = min(
            max(textScale + delta, limits.lowerBound),
            limits.upperBound
        )
        adapter.setTextScale(textScale)
    }

    func resetTextScale() {
        textScale = 1
        adapter.setTextScale(textScale)
    }

    func applyAppearance(_ preferences: QuietReadingPreferences) {
        switch backend {
        case .web(let adapter):
            adapter.setAppearance(preferences)
        case .pdf(let adapter):
            adapter.setAppearance(preferences)
        }
    }

    private func scheduleScalePersistence(_ scale: Double) {
        textScale = scale
        pendingScale = scale
        scalePersistenceTask?.cancel()
        scalePersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persistPendingScale()
        }
    }

    private func persistPendingScale() {
        guard let pendingScale else { return }
        do {
            try store?.saveDevicePreferences(
                DeviceReaderPreferences(scale: pendingScale),
                publicationID: book.id
            )
            self.pendingScale = nil
        } catch {
            statusMessage = "Reader could not save this display preference."
        }
    }

    func persistReadingState() async {
        persistPendingScale()
        guard let store else { return }
        let locator = await adapter.currentLocator()
        guard !hasRecordedOpen || locator != lastPersistedLocator else {
            return
        }

        let progress: Double
        if adapter.format == .pdf {
            progress = adapter.resourceCount <= 1
                ? 0
                : Double(resourceIndex) / Double(adapter.resourceCount - 1)
        } else {
            progress = adapter.resourceCount == 0
                ? 0
                : (Double(resourceIndex) + locator.progression)
                    / Double(adapter.resourceCount)
        }

        do {
            try store.saveReadingState(
                publicationID: book.id,
                locator: locator,
                progress: progress
            )
            lastPersistedLocator = locator
            hasRecordedOpen = true
            onProgressChanged?(progress)
            onReadingStateChanged?()
        } catch {
            statusMessage = "Reader could not save your place."
        }
    }

    func applySyncedReadingState(_ state: StoredReadingState) {
        guard let locator = state.locator else { return }
        adapter.navigate(to: locator)
        resourceIndex = adapter.currentResourceIndex
        lastPersistedLocator = locator
        hasRecordedOpen = true
        onProgressChanged?(state.progress)
    }
}

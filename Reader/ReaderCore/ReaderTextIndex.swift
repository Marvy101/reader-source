import Foundation

struct ReaderTextIndex: Sendable {
    let publicationFingerprint: String
    let chunks: [PublicationTextChunk]
    private let foldedChunks: [String]?

    init(publicationFingerprint: String, chunks: [PublicationTextChunk]) {
        self.publicationFingerprint = publicationFingerprint
        self.chunks = chunks
        foldedChunks = nil
    }

    private init(
        publicationFingerprint: String,
        chunks: [PublicationTextChunk],
        foldedChunks: [String]
    ) {
        self.publicationFingerprint = publicationFingerprint
        self.chunks = chunks
        self.foldedChunks = foldedChunks
    }

    func preparedForSearch() -> ReaderTextIndex {
        guard foldedChunks == nil else { return self }
        return ReaderTextIndex(
            publicationFingerprint: publicationFingerprint,
            chunks: chunks,
            foldedChunks: chunks.map {
                $0.text.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
            }
        )
    }

    func sentence(at locator: ReaderLocator) -> String? {
        guard let chunk = chunks.first(where: { $0.resourceID == locator.resourceID }) else {
            return locator.textAnchor?.exact
        }
        let offset = min(max(locator.position, 0), chunk.text.count)
        guard let position = chunk.text.index(
            chunk.text.startIndex,
            offsetBy: offset,
            limitedBy: chunk.text.endIndex
        ) else { return locator.textAnchor?.exact }
        let sentenceStart = chunk.text[..<position].lastIndex(where: {
            ".!?\n".contains($0)
        }).map { chunk.text.index(after: $0) } ?? chunk.text.startIndex
        let sentenceEnd = chunk.text[position...].firstIndex(where: {
            ".!?".contains($0)
        }).map { chunk.text.index(after: $0) } ?? chunk.text.endIndex
        let sentence = chunk.text[sentenceStart..<sentenceEnd]
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? locator.textAnchor?.exact : sentence
    }

    func search(_ rawQuery: String, limit: Int = 100) -> [ReaderSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let foldedQuery = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        var results: [ReaderSearchResult] = []

        for (chunkIndex, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { return [] }
            let foldedText = foldedChunks?[chunkIndex] ?? chunk.text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            var searchStart = foldedText.startIndex
            var sourceSearchStart = chunk.text.startIndex
            var characterOffset = 0

            while
                results.count < limit,
                let range = foldedText.range(
                    of: foldedQuery,
                    range: searchStart..<foldedText.endIndex
                )
            {
                guard !Task.isCancelled else { return [] }
                let distanceToMatch = foldedText.distance(
                    from: searchStart,
                    to: range.lowerBound
                )
                guard
                    let matchStart = chunk.text.index(
                        sourceSearchStart,
                        offsetBy: distanceToMatch,
                        limitedBy: chunk.text.endIndex
                    ),
                    let matchEnd = chunk.text.index(
                        matchStart,
                        offsetBy: query.count,
                        limitedBy: chunk.text.endIndex
                    )
                else { break }
                characterOffset += distanceToMatch
                let matchRange = matchStart..<matchEnd
                let sourceRange = sourceExcerptRange(
                    in: chunk.text,
                    matchRange: matchRange
                )
                let exact = String(chunk.text[matchRange])
                let prefix = context(
                    in: chunk.text,
                    endingAt: matchStart,
                    maximumLength: 48
                )
                let suffix = context(
                    in: chunk.text,
                    startingAt: matchEnd,
                    maximumLength: 48
                )
                let locator = ReaderLocator(
                    publicationFingerprint: publicationFingerprint,
                    resourceID: chunk.resourceID,
                    position: characterOffset,
                    progression: chunk.text.isEmpty
                        ? 0
                        : Double(characterOffset) / Double(chunk.text.count),
                    textAnchor: TextAnchor(
                        exact: exact,
                        prefix: prefix,
                        suffix: suffix
                    )
                )

                results.append(
                    ReaderSearchResult(
                        locator: locator,
                        excerpt: String(chunk.text[sourceRange])
                            .replacingOccurrences(
                                of: #"\s+"#,
                                with: " ",
                                options: .regularExpression
                            )
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        resourceTitle: chunk.title
                    )
                )

                searchStart = range.upperBound
                sourceSearchStart = matchEnd
                characterOffset += query.count
            }

            if results.count >= limit {
                break
            }
        }

        return results
    }

    func context(
        around selection: ReaderSelection,
        maximumCharactersPerSide: Int = 1_500
    ) -> ReaderSelectionContext {
        guard
            maximumCharactersPerSide > 0,
            let chunkIndex = chunks.firstIndex(where: {
                $0.resourceID == selection.locator.resourceID
            })
        else {
            return ReaderSelectionContext(before: "", after: "")
        }

        let chunk = chunks[chunkIndex]
        let startOffset = min(max(selection.locator.position, 0), chunk.text.count)
        let endOffset = min(
            startOffset + selection.selectedText.count,
            chunk.text.count
        )
        let beforeInChunk = prefix(
            of: chunk.text,
            endingAt: startOffset,
            maximumLength: maximumCharactersPerSide
        )
        let afterInChunk = suffix(
            of: chunk.text,
            startingAt: endOffset,
            maximumLength: maximumCharactersPerSide
        )

        var beforeParts: [String] = []
        var remainingBefore = maximumCharactersPerSide - beforeInChunk.count
        var previousIndex = chunkIndex - 1
        while remainingBefore > 0, previousIndex >= 0 {
            let text = chunks[previousIndex].text
            let part = String(text.suffix(remainingBefore))
            if !part.isEmpty { beforeParts.insert(part, at: 0) }
            remainingBefore -= part.count
            previousIndex -= 1
        }
        if !beforeInChunk.isEmpty { beforeParts.append(beforeInChunk) }

        var afterParts: [String] = []
        if !afterInChunk.isEmpty { afterParts.append(afterInChunk) }
        var remainingAfter = maximumCharactersPerSide - afterInChunk.count
        var nextIndex = chunkIndex + 1
        while remainingAfter > 0, nextIndex < chunks.count {
            let text = chunks[nextIndex].text
            let part = String(text.prefix(remainingAfter))
            if !part.isEmpty { afterParts.append(part) }
            remainingAfter -= part.count
            nextIndex += 1
        }

        return ReaderSelectionContext(
            before: beforeParts.joined(separator: "\n\n"),
            after: afterParts.joined(separator: "\n\n")
        )
    }

    private func prefix(
        of text: String,
        endingAt offset: Int,
        maximumLength: Int
    ) -> String {
        guard let end = text.index(
            text.startIndex,
            offsetBy: offset,
            limitedBy: text.endIndex
        ) else { return "" }
        let start = text.index(
            end,
            offsetBy: -maximumLength,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        return String(text[start..<end])
    }

    private func suffix(
        of text: String,
        startingAt offset: Int,
        maximumLength: Int
    ) -> String {
        guard let start = text.index(
            text.startIndex,
            offsetBy: offset,
            limitedBy: text.endIndex
        ) else { return "" }
        let end = text.index(
            start,
            offsetBy: maximumLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        return String(text[start..<end])
    }

    private func sourceExcerptRange(
        in text: String,
        matchRange match: Range<String.Index>
    ) -> Range<String.Index> {
        let lower = text.index(
            match.lowerBound,
            offsetBy: -70,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let upper = text.index(
            match.upperBound,
            offsetBy: 110,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        return lower..<upper
    }

    private func context(
        in text: String,
        endingAt end: String.Index,
        maximumLength: Int
    ) -> String {
        let start = text.index(
            end,
            offsetBy: -maximumLength,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        return String(text[start..<end])
    }

    private func context(
        in text: String,
        startingAt start: String.Index,
        maximumLength: Int
    ) -> String {
        let end = text.index(
            start,
            offsetBy: maximumLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        return String(text[start..<end])
    }
}

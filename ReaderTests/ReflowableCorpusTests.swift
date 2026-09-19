import Foundation
import WebKit
import XCTest
@testable import Reader

@MainActor
final class ReflowableCorpusTests: XCTestCase {
    func testEPUBPageEstimateUsesStableReaderPageDefinition() {
        XCTAssertEqual(ReflowablePageEstimator.estimate(wordCount: 0), 1)
        XCTAssertEqual(ReflowablePageEstimator.estimate(wordCount: 275), 1)
        XCTAssertEqual(ReflowablePageEstimator.estimate(wordCount: 276), 2)
        XCTAssertEqual(ReflowablePageEstimator.estimate(wordCount: 550), 2)
    }

    func testPlainTextNoteMarkerOpensItsExistingAnnotation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ReaderNoteMarker-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appending(path: "margin-notes.txt")
        try Data(
            "The margin should remember where this thought belongs.".utf8
        ).write(to: sourceURL)
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let adapter = try WebKitReadingAdapter(
            reference: PublicationReference(
                sourceURL: sourceURL,
                format: .plainText,
                fingerprint: fingerprint,
                coverURL: nil
            )
        )
        try await waitForReaderRuntime(in: adapter.webView)

        let result = try XCTUnwrap(
            ReaderTextIndex(
                publicationFingerprint: fingerprint,
                chunks: try adapter.textChunks()
            ).search("where this thought").first
        )
        let annotationID = UUID()
        var openedRequest: ReaderAnnotationNoteRequest?
        adapter.onAnnotationNoteRequested = { openedRequest = $0 }
        adapter.display(
            annotations: [
                ReaderAnnotation(
                    id: annotationID,
                    publicationFingerprint: fingerprint,
                    locator: result.locator,
                    selectedText: "where this thought",
                    note: "This is the part I want to return to.",
                    highlightColor: .aqua
                )
            ]
        )

        for _ in 0..<20 {
            if await evaluateInt(
                "document.querySelectorAll('.reader-note-marker').length",
                in: adapter.webView
            ) == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let markerCount = await evaluateInt(
            "document.querySelectorAll('.reader-note-marker').length",
            in: adapter.webView
        )
        let leaderCount = await evaluateInt(
            "document.querySelectorAll('.reader-note-leader').length",
            in: adapter.webView
        )
        XCTAssertEqual(markerCount, 1)
        XCTAssertEqual(leaderCount, 1)
        let markerInteractionContract = await evaluateBool(
            """
            (() => {
              const marker = document.querySelector('.reader-note-marker');
              if (!marker) return false;
              const style = getComputedStyle(marker);
              return marker.getAttribute('aria-label') === 'Open or move note'
                && parseFloat(style.width) >= 32
                && parseFloat(style.height) >= 32;
            })()
            """,
            in: adapter.webView
        )
        XCTAssertEqual(markerInteractionContract, true)

        let clicked = await evaluateBool(
            """
            (() => {
              const marker = document.querySelector('.reader-note-marker');
              if (!marker) return false;
              marker.click();
              return true;
            })()
            """,
            in: adapter.webView
        )
        XCTAssertEqual(clicked, true)
        for _ in 0..<20 where openedRequest == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(openedRequest?.annotationID, annotationID)
        XCTAssertNotNil(openedRequest?.viewportPoint)

        var movedRequest: ReaderAnnotationNotePlacementRequest?
        adapter.onAnnotationNotePlacementChanged = { movedRequest = $0 }
        let dragged = await evaluateBool(
            """
            (() => {
              const marker = document.querySelector('.reader-note-marker');
              if (!marker || !window.PointerEvent) return false;
              const rect = marker.getBoundingClientRect();
              const x = rect.left + rect.width / 2;
              const y = rect.top + rect.height / 2;
              const walker = document.createTreeWalker(
                document.body,
                NodeFilter.SHOW_TEXT
              );
              const textNode = walker.nextNode();
              if (!textNode || !textNode.data.length) return false;
              const selectionRange = document.createRange();
              selectionRange.setStart(textNode, 0);
              selectionRange.setEnd(textNode, 1);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(selectionRange);
              const event = (kind, nextX, nextY) => new PointerEvent(kind, {
                bubbles: true,
                pointerId: 17,
                clientX: nextX,
                clientY: nextY,
                button: 0,
                buttons: kind === 'pointerup' ? 0 : 1
              });
              const originalLeft = marker.style.left;
              marker.dispatchEvent(event('pointerdown', x, y));
              const selectionWasCleared = selection.isCollapsed;
              marker.dispatchEvent(event('pointermove', x + 3, y + 3));
              const clickDidNotJitter = marker.style.left === originalLeft;
              marker.dispatchEvent(event('pointermove', x - 84, y + 56));
              const dragWasActive = marker.dataset.dragging === 'true'
                && document.documentElement.classList.contains(
                  'reader-note-dragging'
                );
              marker.dispatchEvent(event('pointerup', x - 84, y + 56));
              const dragWasCleanedUp = !marker.dataset.dragging
                && !document.documentElement.classList.contains(
                  'reader-note-dragging'
                );
              return selectionWasCleared
                && clickDidNotJitter
                && dragWasActive
                && dragWasCleanedUp;
            })()
            """,
            in: adapter.webView
        )
        XCTAssertEqual(dragged, true)
        for _ in 0..<20 where movedRequest == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(movedRequest?.annotationID, annotationID)
        XCTAssertLessThan(movedRequest?.placement.horizontalOffset ?? 0, -0.02)
        XCTAssertGreaterThan(movedRequest?.placement.verticalOffset ?? 0, 0.02)

        adapter.display(
            annotations: [
                ReaderAnnotation(
                    id: annotationID,
                    publicationFingerprint: fingerprint,
                    locator: result.locator,
                    selectedText: "where this thought",
                    note: nil,
                    highlightColor: .aqua
                )
            ]
        )
        try await Task.sleep(for: .milliseconds(50))
        let clearedMarkerCount = await evaluateInt(
            "document.querySelectorAll('.reader-note-marker').length",
            in: adapter.webView
        )
        XCTAssertEqual(clearedMarkerCount, 0)
    }

    func testCustomEPUBLoaderOpensMemorableBooksAndFindsCovers() async throws {
        let fixtures = [
            "alice-wonderland.epub",
            "moby-dick.epub",
            "war-and-peace.epub",
            "pride-and-prejudice-illustrated.epub"
        ]

        try requireDownloadedCorpus()

        for fileName in fixtures {
            let publication = try EPUBPublicationLoader.load(
                from: downloadDirectory.appending(path: fileName)
            )

            XCTAssertFalse(publication.title.isEmpty, fileName)
            XCTAssertFalse(publication.author.isEmpty, fileName)
            XCTAssertFalse(publication.spine.isEmpty, fileName)
            XCTAssertFalse(publication.tableOfContents.isEmpty, fileName)
            XCTAssertGreaterThan(
                ReflowablePageEstimator.estimate(resources: publication.spine),
                1,
                fileName
            )
            XCTAssertTrue(
                publication.spine.allSatisfy {
                    FileManager.default.fileExists(atPath: $0.fileURL.path)
                },
                fileName
            )
            let coverURL = try XCTUnwrap(publication.coverURL, fileName)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: coverURL.path),
                fileName
            )

            let adapter = try WebKitReadingAdapter(
                reference: PublicationReference(
                    sourceURL: downloadDirectory.appending(path: fileName),
                    format: .epub,
                    fingerprint: publication.fingerprint,
                    coverURL: coverURL
                )
            )
            try await waitForReaderRuntime(in: adapter.webView)
            let renderedResourceCount = await evaluateInt(
                "document.querySelectorAll('.reader-resource').length",
                in: adapter.webView
            )
            XCTAssertEqual(
                renderedResourceCount,
                publication.spine.count,
                fileName
            )
        }
    }

    func testMobyDickUsesSourceChaptersAndOneContinuousDocument() async throws {
        try requireDownloadedCorpus()
        let sourceURL = downloadDirectory.appending(path: "moby-dick.epub")
        let publication = try EPUBPublicationLoader.load(from: sourceURL)
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let adapter = try WebKitReadingAdapter(
            reference: PublicationReference(
                sourceURL: sourceURL,
                format: .epub,
                fingerprint: fingerprint,
                coverURL: publication.coverURL
            )
        )

        XCTAssertGreaterThan(publication.tableOfContents.count, 130)
        XCTAssertGreaterThan(adapter.sections.count, 130)
        let chapterNine = try XCTUnwrap(
            adapter.sections.first {
                $0.title.localizedCaseInsensitiveContains(
                    "CHAPTER 9. The Sermon"
                )
            }
        )
        XCTAssertNotNil(chapterNine.fragment)

        try await waitForReaderRuntime(in: adapter.webView)
        let resourceCount = await evaluateInt(
            "document.querySelectorAll('.reader-resource').length",
            in: adapter.webView
        )
        XCTAssertEqual(resourceCount, publication.spine.count)
        XCTAssertEqual(
            adapter.webView.url?.lastPathComponent,
            "continuous.html"
        )
        let coverFlowsIntoBook = await evaluateBool(
            """
            (() => {
              const resources = Array.from(
                document.querySelectorAll('.reader-resource')
              );
              return resources.length > 1
                && resources[1].getBoundingClientRect().top
                  > resources[0].getBoundingClientRect().top
                && document.documentElement.scrollHeight > window.innerHeight;
            })()
            """,
            in: adapter.webView
        )
        XCTAssertEqual(coverFlowsIntoBook, true)
        let containsBoundaryChapters = await evaluateBool(
            """
            document.body.innerText.includes("CHAPTER 8. The Pulpit.")
              && document.body.innerText.includes("CHAPTER 9. The Sermon.")
            """,
            in: adapter.webView
        )
        XCTAssertEqual(containsBoundaryChapters, true)

        adapter.navigate(to: chapterNine)
        try await waitForSection(chapterNine, in: adapter.webView)
    }

    func testCustomEPUBAdapterFeedsSharedSearchIndexAndAnnotations() async throws {
        try requireDownloadedCorpus()
        let sourceURL = downloadDirectory.appending(path: "alice-wonderland.epub")
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let adapter = try WebKitReadingAdapter(
            reference: PublicationReference(
                sourceURL: sourceURL,
                format: .epub,
                fingerprint: fingerprint,
                coverURL: nil
            )
        )
        let chunks = try adapter.textChunks()
        let index = ReaderTextIndex(
            publicationFingerprint: fingerprint,
            chunks: chunks
        )

        XCTAssertFalse(
            adapter.webView.configuration.defaultWebpagePreferences
                .allowsContentJavaScript
        )
        XCTAssertFalse(adapter.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(
            adapter.webView.configuration.userContentController.userScripts
                .contains { $0.source.contains("Content-Security-Policy") }
        )
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertGreaterThan(chunks.reduce(0) { $0 + $1.text.count }, 50_000)
        let result = try XCTUnwrap(index.search("curiouser and curiouser").first)
        XCTAssertEqual(result.locator.publicationFingerprint, fingerprint)
        XCTAssertFalse(result.locator.resourceID.isEmpty)
        XCTAssertEqual(
            result.locator.textAnchor?.exact.lowercased(),
            "curiouser and curiouser"
        )

        adapter.navigate(to: result.locator)
        try await waitForText(
            "Curiouser and curiouser",
            in: adapter.webView
        )
        _ = await evaluateBool(
            """
            (() => {
              const walker = document.createTreeWalker(
                document.body,
                NodeFilter.SHOW_TEXT
              );
              const needle = "Curiouser and curiouser";
              while (walker.nextNode()) {
                const offset = walker.currentNode.data.indexOf(needle);
                if (offset >= 0) {
                  const range = document.createRange();
                  range.setStart(walker.currentNode, offset);
                  range.setEnd(walker.currentNode, offset + needle.length);
                  const selection = window.getSelection();
                  selection.removeAllRanges();
                  selection.addRange(range);
                  return true;
                }
              }
              return false;
            })()
            """,
            in: adapter.webView
        )

        let captured = await adapter.captureSelection()
        let readerSelection = try XCTUnwrap(captured)
        XCTAssertEqual(
            readerSelection.selectedText.lowercased(),
            "curiouser and curiouser"
        )
        adapter.display(
            annotations: [
                ReaderAnnotation(
                    publicationFingerprint: fingerprint,
                    locator: readerSelection.locator,
                    selectedText: readerSelection.selectedText
                )
            ]
        )
        try await Task.sleep(for: .milliseconds(100))
        let hasHighlight = await evaluateBool(
            """
            Boolean(
              window.CSS &&
              CSS.highlights &&
              CSS.highlights.has('reader-highlight-lemon')
            )
            """,
            in: adapter.webView
        )
        XCTAssertEqual(hasHighlight, true)
    }

    func testEPUBAdapterFeedsTheSharedSearchIndex() async throws {
        try requireDownloadedCorpus()
        let sourceURL = downloadDirectory.appending(path: "alice-wonderland.epub")
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let adapter = try WebKitReadingAdapter(
            reference: PublicationReference(
                sourceURL: sourceURL,
                format: .epub,
                fingerprint: fingerprint,
                coverURL: nil
            )
        )
        let index = ReaderTextIndex(
            publicationFingerprint: fingerprint,
            chunks: try adapter.textChunks()
        )

        let searchResults = index.search("curiouser and curiouser", limit: 3)
        let result = try XCTUnwrap(searchResults.first)
        XCTAssertEqual(result.locator.publicationFingerprint, fingerprint)
        XCTAssertFalse(result.locator.resourceID.isEmpty)
        XCTAssertEqual(
            result.locator.textAnchor?.exact.lowercased(),
            "curiouser and curiouser"
        )

        try await waitForReaderRuntime(in: adapter.webView)
        let highlightResults = index.search("alice", limit: 3)
        XCTAssertEqual(highlightResults.count, 3)
        adapter.display(searchResults: highlightResults, activeIndex: 0)
        try await Task.sleep(for: .milliseconds(100))
        let searchHighlightsExist = await evaluateBool(
            """
            Boolean(
              window.CSS && CSS.highlights
              && CSS.highlights.has('reader-search-match')
              && CSS.highlights.has('reader-search-active')
            )
            """,
            in: adapter.webView
        )
        XCTAssertEqual(searchHighlightsExist, true)

        adapter.display(searchResults: [], activeIndex: nil)
        try await Task.sleep(for: .milliseconds(100))
        let searchHighlightsCleared = await evaluateBool(
            """
            Boolean(
              window.CSS && CSS.highlights
              && !CSS.highlights.has('reader-search-match')
              && !CSS.highlights.has('reader-search-active')
            )
            """,
            in: adapter.webView
        )
        XCTAssertEqual(searchHighlightsCleared, true)
    }

    func testPlainTextAdapterFeedsTheSameSearchIndex() throws {
        try requireDownloadedCorpus()
        let sourceURL = downloadDirectory.appending(path: "alice-wonderland.txt")
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let adapter = try WebKitReadingAdapter(
            reference: PublicationReference(
                sourceURL: sourceURL,
                format: .plainText,
                fingerprint: fingerprint,
                coverURL: nil
            )
        )
        let chunks = try adapter.textChunks()
        let index = ReaderTextIndex(
            publicationFingerprint: fingerprint,
            chunks: chunks
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertGreaterThan(chunks[0].text.count, 100_000)
        let result = try XCTUnwrap(index.search("curiouser and curiouser").first)
        XCTAssertEqual(result.locator.resourceID, "text")
        XCTAssertEqual(result.locator.publicationFingerprint, fingerprint)
    }

    func testFindSessionReportsCountAndWrapsThroughMatches() throws {
        try requireDownloadedCorpus()
        let sourceURL = downloadDirectory.appending(path: "alice-wonderland.txt")
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let session = try PublicationReaderSession(
            book: Book(
                title: "Alice's Adventures in Wonderland",
                author: "Lewis Carroll",
                progress: 0,
                coverStyle: .parchment,
                formatLabel: "TXT",
                readingLength: .reflowable,
                sample: ReadingSample(chapter: "", section: "", paragraphs: []),
                publication: PublicationReference(
                    sourceURL: sourceURL,
                    format: .plainText,
                    fingerprint: fingerprint,
                    coverURL: nil
                )
            )
        )

        session.searchQuery = "curiouser"
        session.search()

        XCTAssertGreaterThan(session.searchResults.count, 1)
        XCTAssertEqual(session.activeSearchResultIndex, 0)
        XCTAssertEqual(
            session.searchResultLabel,
            "1 of \(session.searchResults.count)"
        )

        let nearbyIndex = min(5, session.searchResults.count - 1)
        XCTAssertEqual(
            session.preferredInitialSearchResultIndex(
                in: session.searchResults,
                nearestTo: session.searchResults[nearbyIndex].locator
            ),
            nearbyIndex
        )

        session.moveSearchResult(by: -1)
        XCTAssertEqual(
            session.activeSearchResultIndex,
            session.searchResults.count - 1
        )

        session.clearSearch()
        XCTAssertTrue(session.searchResults.isEmpty)
        XCTAssertNil(session.activeSearchResultIndex)
        XCTAssertEqual(session.searchResultLabel, "")
    }

    func testScheduledFindKeepsTheLatestTypedQuery() async throws {
        try requireDownloadedCorpus()
        let sourceURL = downloadDirectory.appending(path: "alice-wonderland.txt")
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let session = try PublicationReaderSession(
            book: Book(
                title: "Alice's Adventures in Wonderland",
                author: "Lewis Carroll",
                progress: 0,
                coverStyle: .parchment,
                formatLabel: "TXT",
                readingLength: .reflowable,
                sample: ReadingSample(chapter: "", section: "", paragraphs: []),
                publication: PublicationReference(
                    sourceURL: sourceURL,
                    format: .plainText,
                    fingerprint: fingerprint,
                    coverURL: nil
                )
            )
        )

        session.searchQuery = "Alice"
        session.scheduleSearch()
        session.searchQuery = "curiouser"
        session.scheduleSearch()

        for _ in 0..<100 where session.searchResults.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(session.searchResults.isEmpty)
        XCTAssertTrue(
            session.searchResults.allSatisfy {
                $0.locator.textAnchor?.exact.lowercased() == "curiouser"
            }
        )
    }

    func testFindNextScrollsEPUBToTheActiveLaterMatch() async throws {
        try requireDownloadedCorpus()
        let sourceURL = downloadDirectory.appending(path: "alice-wonderland.epub")
        let publication = try EPUBPublicationLoader.load(from: sourceURL)
        let session = try PublicationReaderSession(
            book: Book(
                title: publication.title,
                author: publication.author,
                progress: 0,
                coverStyle: .parchment,
                formatLabel: "EPUB",
                readingLength: .reflowable,
                sample: ReadingSample(chapter: "", section: "", paragraphs: []),
                publication: PublicationReference(
                    sourceURL: sourceURL,
                    format: .epub,
                    fingerprint: publication.fingerprint,
                    coverURL: publication.coverURL
                )
            )
        )
        guard case .web(let adapter) = session.backend else {
            return XCTFail("Expected the WebKit adapter")
        }
        adapter.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        try await waitForReaderRuntime(in: adapter.webView)

        session.searchQuery = "Alice"
        session.search()
        let first = try XCTUnwrap(session.searchResults.first)
        let targetIndex = try XCTUnwrap(
            session.searchResults.firstIndex {
                $0.locator.resourceID == first.locator.resourceID
                    && $0.locator.position > first.locator.position + 1_000
            }
        )

        session.activeSearchResultIndex = targetIndex - 1
        session.moveSearchResult(by: 1)

        var activeMatchIsVisible = false
        for _ in 0..<80 {
            activeMatchIsVisible = await evaluateBool(
                """
                (() => {
                  const highlight = window.CSS && CSS.highlights
                    ? CSS.highlights.get('reader-search-active')
                    : null;
                  const range = highlight ? Array.from(highlight)[0] : null;
                  if (!range) return false;
                  const rect = range.getBoundingClientRect();
                  return rect.bottom >= 0 && rect.top <= window.innerHeight;
                })()
                """,
                in: adapter.webView
            ) == true
            if activeMatchIsVisible { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(session.activeSearchResultIndex, targetIndex)
        XCTAssertTrue(activeMatchIsVisible)

        let rapidMoveCount = min(6, session.searchResults.count - 1)
        for _ in 0..<rapidMoveCount {
            session.moveSearchResult(by: 1)
        }
        let expectedRapidIndex = (targetIndex + rapidMoveCount)
            % session.searchResults.count
        var runtimeReachedExpectedIndex = false
        for _ in 0..<40 {
            runtimeReachedExpectedIndex = await evaluateBool(
                "window.ReaderRuntime.activeSearchResultIndex === \(expectedRapidIndex)",
                in: adapter.webView
            ) == true
            if runtimeReachedExpectedIndex { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(session.activeSearchResultIndex, expectedRapidIndex)
        XCTAssertTrue(runtimeReachedExpectedIndex)
    }

    private var downloadDirectory: URL {
        if let overridePath = ProcessInfo.processInfo.environment[
            "READER_TEST_CORPUS_DIR"
        ] {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }

        return ReaderTestCorpus.downloadDirectory
    }

    private func requireDownloadedCorpus() throws {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: downloadDirectory.path),
            "Run scripts/download_test_corpus.sh first."
        )
    }

    private func waitForReaderRuntime(in webView: WKWebView) async throws {
        for _ in 0..<40 {
            if
                let ready = await evaluateBool(
                    "Boolean(window.ReaderRuntime)",
                    in: webView
                ),
                ready
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The Reader WebKit runtime did not finish loading.")
    }

    private func waitForText(
        _ text: String,
        in webView: WKWebView
    ) async throws {
        let encodedText = try XCTUnwrap(
            String(data: JSONEncoder().encode(text), encoding: .utf8)
        )
        for _ in 0..<60 {
            if
                let found = await evaluateBool(
                    """
                    Boolean(
                      document.body &&
                      document.body.innerText.includes(\(encodedText))
                    )
                    """,
                    in: webView
                ),
                found
            {
                try await waitForReaderRuntime(in: webView)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The expected EPUB passage did not finish loading.")
    }

    private func evaluateBool(
        _ script: String,
        in webView: WKWebView
    ) async -> Bool? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? Bool)
            }
        }
    }

    private func evaluateInt(
        _ script: String,
        in webView: WKWebView
    ) async -> Int? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? Int)
            }
        }
    }

    private func waitForSection(
        _ section: ReaderSection,
        in webView: WKWebView
    ) async throws {
        let fragment = try XCTUnwrap(section.fragment)
        let encodedFragment = try XCTUnwrap(
            String(data: JSONEncoder().encode(fragment), encoding: .utf8)
        )
        for _ in 0..<60 {
            if
                let reached = await evaluateBool(
                    """
                    (() => {
                      const target = document.getElementById(\(encodedFragment));
                      return Boolean(
                        target
                        && Math.abs(target.getBoundingClientRect().top - 54) < 12
                      );
                    })()
                    """,
                    in: webView
                ),
                reached
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The contents selection did not reach \(section.title).")
    }
}

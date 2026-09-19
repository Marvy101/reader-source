import Foundation
import SwiftUI
import WebKit

private struct WebReadingResource: Sendable {
    let id: String
    let title: String?
    let fileURL: URL
    let text: String
}

private struct WebSelectionPayload: Codable {
    let resourceID: String
    let exact: String
    let prefix: String
    let suffix: String
    let start: Int
    let progression: Double
    let viewportX: Double
    let viewportY: Double
}

private struct WebLocationPayload: Codable {
    let resourceID: String
    let position: Int
    let progression: Double
}

private struct WebInlineRewriteActionPayload: Decodable {
    let action: String
    let instruction: String?
}

@MainActor
private final class ReaderAnnotationNoteScriptMessageHandler: NSObject,
    WKScriptMessageHandler {
    weak var target: WebKitReadingAdapter?

    init(target: WebKitReadingAdapter) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class WebKitReadingAdapter: NSObject, ReadingAdapter, WKNavigationDelegate,
    WKScriptMessageHandler {
    let format: PublicationFormat
    let fingerprint: String
    let capabilities: ReadingCapabilities
    let webView: WKWebView
    let sections: [ReaderSection]
    var onResourceIndexChanged: ((Int) -> Void)?
    var onScaleChanged: ((Double) -> Void)?
    var onAnnotationNoteRequested: ((ReaderAnnotationNoteRequest) -> Void)?
    var onAnnotationNotePlacementChanged: ((ReaderAnnotationNotePlacementRequest) -> Void)?

    private let rootDirectory: URL
    private let documentURL: URL
    private let resources: [WebReadingResource]
    private var annotationNoteScriptMessageHandler: ReaderAnnotationNoteScriptMessageHandler?
    private var annotations: [ReaderAnnotation] = []
    private var searchResults: [ReaderSearchResult] = []
    private var activeSearchResultIndex: Int?
    private var pendingLocator: ReaderLocator?
    private var pendingLocatorIsAnimated = true
    private var textScale = 1.0
    private var readingSize = 20
    private var usesSerif = false
    private var readingTheme = QuietReadingTheme.white
    private var isDocumentLoaded = false

    private(set) var currentResourceIndex = 0
    private(set) var selectionViewportAnchor: ReaderViewportPoint?

    init(reference: PublicationReference) throws {
        self.format = reference.format
        self.fingerprint = reference.fingerprint

        let resolvedRootDirectory: URL
        let resolvedDocumentURL: URL
        let resolvedResources: [WebReadingResource]
        let resolvedSections: [ReaderSection]

        switch reference.format {
        case .epub:
            let publication = try EPUBPublicationLoader.load(
                from: reference.sourceURL
            )
            resolvedRootDirectory = publication.rootDirectory
            resolvedDocumentURL = try EPUBContinuousDocumentBuilder.build(
                publication: publication
            )
            resolvedResources = publication.spine.enumerated().map { index, resource in
                let extracted = XHTMLTextExtractor.extract(from: resource.fileURL)
                return WebReadingResource(
                    id: resource.id,
                    title: extracted.title ?? "Section \(index + 1)",
                    fileURL: resource.fileURL,
                    text: extracted.text
                )
            }
            resolvedSections = publication.tableOfContents.enumerated().map {
                index,
                item in
                ReaderSection(
                    id: "epub-toc-\(index)-\(item.resourceID)",
                    title: item.title,
                    resourceID: item.resourceID,
                    fragment: item.fragment,
                    depth: item.depth
                )
            }
        case .plainText:
            let publication = try PlainTextPublication.load(
                from: reference.sourceURL
            )
            resolvedRootDirectory = publication.rootDirectory
            resolvedDocumentURL = publication.documentURL
            resolvedResources = [
                WebReadingResource(
                    id: "text",
                    title: publication.title,
                    fileURL: publication.documentURL,
                    text: publication.text.normalizedReaderWhitespace
                )
            ]
            resolvedSections = []
        case .pdf:
            throw PublicationImportError.unsupportedFormat
        }

        self.rootDirectory = resolvedRootDirectory
        self.documentURL = resolvedDocumentURL
        self.resources = resolvedResources
        self.sections = resolvedSections
        var resolvedCapabilities: ReadingCapabilities = [
            .selectableText,
            .search,
            .highlights,
            .reflow
        ]
        if !resolvedSections.isEmpty {
            resolvedCapabilities.insert(.tableOfContents)
        }
        self.capabilities = resolvedCapabilities

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.securityRuntime,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.readerRuntime,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let annotationNoteScriptMessageHandler = ReaderAnnotationNoteScriptMessageHandler(
            target: self
        )
        self.annotationNoteScriptMessageHandler = annotationNoteScriptMessageHandler
        configuration.userContentController.add(
            annotationNoteScriptMessageHandler,
            name: "readerAnnotationNote"
        )
        configuration.userContentController.add(
            annotationNoteScriptMessageHandler,
            name: "readerAnnotationNotePlacement"
        )
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        loadDocument()
    }

    var resourceCount: Int {
        resources.count
    }

    func textChunks() throws -> [PublicationTextChunk] {
        resources.enumerated().map { index, resource in
            PublicationTextChunk(
                resourceID: resource.id,
                title: resource.title,
                text: resource.text,
                ordinal: index
            )
        }
    }

    static func resumeTextChunk(
        reference: PublicationReference,
        locator: ReaderLocator
    ) throws -> PublicationTextChunk? {
        switch reference.format {
        case .epub:
            let publication = try EPUBPublicationLoader.load(
                from: reference.sourceURL
            )
            guard
                let index = publication.spine.firstIndex(where: {
                    $0.id == locator.resourceID
                })
            else { return nil }
            let resource = publication.spine[index]
            let extracted = XHTMLTextExtractor.extract(from: resource.fileURL)
            return PublicationTextChunk(
                resourceID: resource.id,
                title: extracted.title ?? "Section \(index + 1)",
                text: extracted.text,
                ordinal: index
            )
        case .plainText:
            let publication = try PlainTextPublication.load(
                from: reference.sourceURL
            )
            return PublicationTextChunk(
                resourceID: "text",
                title: publication.title,
                text: publication.text.normalizedReaderWhitespace,
                ordinal: 0
            )
        case .pdf:
            throw PublicationImportError.unsupportedFormat
        }
    }

    func navigate(to locator: ReaderLocator) {
        navigate(to: locator, animated: true)
    }

    func navigate(toSearchResult locator: ReaderLocator) {
        navigate(to: locator, animated: false)
    }

    private func navigate(to locator: ReaderLocator, animated: Bool) {
        guard
            let resourceIndex = resources.firstIndex(where: {
                $0.id == locator.resourceID
            })
        else {
            return
        }

        currentResourceIndex = resourceIndex
        onResourceIndexChanged?(resourceIndex)
        pendingLocator = locator
        pendingLocatorIsAnimated = animated
        if isDocumentLoaded {
            applyPendingLocator()
        }
    }

    func navigate(to section: ReaderSection) {
        guard
            let resourceIndex = resources.firstIndex(where: {
                $0.id == section.resourceID
            })
        else {
            return
        }

        currentResourceIndex = resourceIndex
        onResourceIndexChanged?(resourceIndex)
        pendingLocator = nil
        let resourceJSON = Self.javaScriptJSON(section.resourceID)
        let fragmentJSON = Self.javaScriptJSON(section.fragment)
        evaluateWithoutResult(
            """
            window.ReaderRuntime && window.ReaderRuntime.navigateToSection(
              \(resourceJSON),
              \(fragmentJSON)
            )
            """
        )
    }

    func moveResource(by offset: Int) {
        let destination = min(
            max(currentResourceIndex + offset, 0),
            max(resources.count - 1, 0)
        )
        guard destination != currentResourceIndex else { return }
        currentResourceIndex = destination
        onResourceIndexChanged?(destination)
        pendingLocator = nil
        let resourceJSON = Self.javaScriptJSON(resources[destination].id)
        evaluateWithoutResult(
            """
            window.ReaderRuntime && window.ReaderRuntime.navigateToSection(
              \(resourceJSON),
              null
            )
            """
        )
    }

    func currentLocator() async -> ReaderLocator {
        let payload = await evaluateString(
            "window.ReaderRuntime ? window.ReaderRuntime.currentLocationJSON() : null"
        )
        .flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode(WebLocationPayload.self, from: $0) }
        if
            let resourceID = payload?.resourceID,
            let index = resources.firstIndex(where: { $0.id == resourceID }),
            index != currentResourceIndex
        {
            currentResourceIndex = index
            onResourceIndexChanged?(index)
        }
        let resourceID = payload?.resourceID
            ?? resources[currentResourceIndex].id
        return ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: resourceID,
            position: payload?.position ?? 0,
            progression: payload?.progression ?? 0
        )
    }

    func captureSelection() async -> ReaderSelection? {
        guard
            let json = await evaluateString(
                "window.ReaderRuntime ? window.ReaderRuntime.selectionJSON() : null"
            ),
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(
                WebSelectionPayload.self,
                from: data
            ),
            !payload.exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            selectionViewportAnchor = nil
            return nil
        }

        selectionViewportAnchor = ReaderViewportPoint(
            x: payload.viewportX,
            y: payload.viewportY
        )

        let locator = ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: payload.resourceID,
            position: payload.start,
            progression: payload.progression,
            textAnchor: TextAnchor(
                exact: payload.exact,
                prefix: payload.prefix,
                suffix: payload.suffix
            )
        )
        return ReaderSelection(locator: locator, selectedText: payload.exact)
    }

    func display(annotations: [ReaderAnnotation]) {
        self.annotations = annotations.filter {
            $0.publicationFingerprint == fingerprint
        }
        applyCurrentAnnotations()
    }

    func display(searchResults: [ReaderSearchResult], activeIndex: Int?) {
        self.searchResults = searchResults.filter {
            $0.locator.publicationFingerprint == fingerprint
        }
        activeSearchResultIndex = activeIndex
        applyCurrentSearchResults()
    }

    func activateSearchResult(at index: Int?) {
        activeSearchResultIndex = index
        let value = index.map(String.init) ?? "null"
        evaluateWithoutResult(
            "window.ReaderRuntime && window.ReaderRuntime.activateSearchResult(\(value))"
        )
    }

    func clearSelection() {
        selectionViewportAnchor = nil
        evaluateWithoutResult("window.getSelection && window.getSelection().removeAllRanges()")
    }

    func beginInlineRewrite(_ selection: ReaderSelection) async -> Bool {
        let exactJSON = Self.javaScriptJSON(selection.selectedText)
        return await evaluateString(
            """
            window.ReaderRuntime
              ? JSON.stringify(window.ReaderRuntime.beginInlineRewrite(\(exactJSON)))
              : "false"
            """
        ) == "true"
    }

    func showInlineRewrite(_ text: String) {
        evaluateWithoutResult(
            "window.ReaderRuntime && window.ReaderRuntime.showInlineRewrite(\(Self.javaScriptJSON(text)))"
        )
    }

    func showInlineRewriteFailure(_ message: String) {
        evaluateWithoutResult(
            "window.ReaderRuntime && window.ReaderRuntime.showInlineRewriteFailure(\(Self.javaScriptJSON(message)))"
        )
    }

    func restartInlineRewriteLoading() {
        evaluateWithoutResult(
            "window.ReaderRuntime && window.ReaderRuntime.restartInlineRewriteLoading()"
        )
    }

    func captureInlineRewriteAction() async -> ReaderInlineRewriteAction? {
        guard
            let json = await evaluateString(
                "window.ReaderRuntime ? window.ReaderRuntime.takeInlineRewriteActionJSON() : null"
            ),
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(
                WebInlineRewriteActionPayload.self,
                from: data
            )
        else { return nil }

        return switch payload.action {
        case "dismiss": .dismiss
        case "retry": .retry
        case "rewrite": .rewrite(instruction: payload.instruction ?? "")
        default: nil
        }
    }

    func dismissInlineRewrite() {
        evaluateWithoutResult(
            "window.ReaderRuntime && window.ReaderRuntime.dismissInlineRewrite()"
        )
    }

    func setTextScale(_ scale: Double) {
        textScale = min(max(scale, 0.75), 2.5)
        webView.setMagnification(
            CGFloat(textScale),
            centeredAt: NSPoint(
                x: webView.bounds.midX,
                y: webView.bounds.midY
            )
        )
        onScaleChanged?(textScale)
    }

    func setAppearance(_ preferences: QuietReadingPreferences) {
        readingSize = preferences.size
        usesSerif = preferences.serif
        readingTheme = preferences.theme
        applyAppearance()
    }

    func changeTextScale(by delta: Double) {
        setTextScale(textScale + delta)
    }

    func didMagnifyNatively() {
        let scale = min(max(Double(webView.magnification), 0.75), 2.5)
        textScale = scale
        onScaleChanged?(scale)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if url.isFileURL {
            let isReaderDocument =
                url.standardizedFileURL.path
                == documentURL.standardizedFileURL.path
            decisionHandler(isReaderDocument ? .allow : .cancel)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isDocumentLoaded = true
        let defaultResourceJSON = Self.javaScriptJSON(
            resources.first?.id ?? "text"
        )
        evaluateWithoutResult(
            """
            window.ReaderRuntime
              && window.ReaderRuntime.setDefaultResourceID(\(defaultResourceJSON))
            """
        )
        setTextScale(textScale)
        applyAppearance()
        applyCurrentAnnotations()
        applyCurrentSearchResults()
        applyPendingLocator()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "readerAnnotationNotePlacement" {
            guard
                let body = message.body as? [String: Any],
                let rawID = body["id"] as? String,
                let annotationID = UUID(uuidString: rawID),
                let horizontalOffset = body["horizontalOffset"] as? Double,
                let verticalOffset = body["verticalOffset"] as? Double,
                annotations.contains(where: { $0.id == annotationID })
            else { return }
            onAnnotationNotePlacementChanged?(
                ReaderAnnotationNotePlacementRequest(
                    annotationID: annotationID,
                    placement: ReaderNotePlacement(
                        horizontalOffset: horizontalOffset,
                        verticalOffset: verticalOffset
                    )
                )
            )
            return
        }

        guard
            message.name == "readerAnnotationNote",
            let body = message.body as? [String: Any],
            let rawID = body["id"] as? String,
            let annotationID = UUID(uuidString: rawID),
            annotations.contains(where: {
                $0.id == annotationID
                    && $0.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            })
        else { return }

        let point: ReaderViewportPoint?
        if let x = body["x"] as? Double, let y = body["y"] as? Double {
            point = ReaderViewportPoint(x: x, y: y)
        } else {
            point = nil
        }
        onAnnotationNoteRequested?(
            ReaderAnnotationNoteRequest(
                annotationID: annotationID,
                viewportPoint: point
            )
        )
    }

    private func loadDocument() {
        webView.loadFileURL(
            documentURL,
            allowingReadAccessTo: rootDirectory
        )
    }

    private func applyPendingLocator() {
        guard let locator = pendingLocator else { return }
        pendingLocator = nil
        let animated = pendingLocatorIsAnimated
        let anchorJSON = Self.javaScriptJSON(locator.textAnchor)
        evaluateWithoutResult(
            """
            window.ReaderRuntime && window.ReaderRuntime.navigate(
              \(locator.position),
              \(anchorJSON),
              \(Self.javaScriptJSON(locator.resourceID)),
              \(animated ? "true" : "false")
            )
            """
        )
    }

    private func applyCurrentAnnotations() {
        let payload = annotations
            .map { annotation in
                var item = [
                    "resourceID": annotation.locator.resourceID,
                    "position": annotation.locator.position,
                    "exact": annotation.locator.textAnchor?.exact ?? "",
                    "color": annotation.highlightColor.rawValue,
                    "id": annotation.id.uuidString,
                    "hasNote": annotation.note?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty == false
                ] as [String: Any]
                if let placement = annotation.notePlacement {
                    item["noteOffsetX"] = placement.horizontalOffset
                    item["noteOffsetY"] = placement.verticalOffset
                }
                return item
            }
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        evaluateWithoutResult(
            "window.ReaderRuntime && window.ReaderRuntime.applyHighlights(\(json))"
        )
    }

    private func applyCurrentSearchResults() {
        let payload = searchResults.enumerated().map { index, result in
            [
                "resourceID": result.locator.resourceID,
                "position": result.locator.position,
                "exact": result.locator.textAnchor?.exact ?? "",
                "active": index == activeSearchResultIndex
            ] as [String: Any]
        }
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else { return }
        evaluateWithoutResult(
            "window.ReaderRuntime && window.ReaderRuntime.applySearchResults(\(json))"
        )
    }

    private func applyAppearance() {
        let colors: (paper: String, ink: String) = switch readingTheme {
        case .white: ("#ffffff", "#26262a")
        case .cream: ("#f6f2e8", "#2a2620")
        case .gray: ("#e6e6e6", "#242426")
        case .dark: ("#1a1a1c", "#dcd8d0")
        }
        let family = usesSerif
            ? "Georgia, 'Iowan Old Style', serif"
            : "-apple-system, 'SF Pro Text', BlinkMacSystemFont, sans-serif"
        evaluateWithoutResult(
            """
            document.documentElement.style.setProperty('--reader-paper', '\(colors.paper)');
            document.documentElement.style.setProperty('--reader-ink', '\(colors.ink)');
            document.documentElement.style.setProperty('--reader-size', '\(readingSize)px');
            document.documentElement.style.setProperty('--reader-family', \(Self.javaScriptJSON(family)));
            requestAnimationFrame(() => window.ReaderRuntime?.refreshNoteMarkers());
            """
        )
    }

    private func evaluateWithoutResult(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func evaluateString(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    private static func javaScriptJSON(_ anchor: TextAnchor?) -> String {
        guard
            let anchor,
            let data = try? JSONEncoder().encode(anchor),
            let json = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return json
    }

    private static func javaScriptJSON(_ string: String?) -> String {
        guard
            let string,
            let data = try? JSONEncoder().encode(string),
            let json = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return json
    }

    private static let securityRuntime = #"""
        (() => {
          const policy = document.createElement("meta");
          policy.httpEquiv = "Content-Security-Policy";
          policy.content = [
            "default-src 'none'",
            "img-src file: data: blob:",
            "style-src file: 'unsafe-inline'",
            "font-src file: data:",
            "media-src file: data: blob:",
            "connect-src 'none'",
            "frame-src 'none'",
            "object-src 'none'",
            "form-action 'none'"
          ].join("; ");
          document.documentElement.prepend(policy);
        })();
        """#

    private static let readerRuntime = #"""
        (() => {
          const style = document.createElement("style");
          style.id = "reader-runtime-style";
          style.textContent = `
            :root {
              color-scheme: light;
              --reader-scale: 1;
              --reader-ink: #252721;
              --reader-paper: #ffffff;
              --reader-moss: #38563f;
              --reader-size: 20px;
              --reader-family: -apple-system, "SF Pro Text", BlinkMacSystemFont, sans-serif;
            }
            html {
              background: transparent !important;
              scroll-behavior: smooth;
            }
            body {
              box-sizing: border-box;
              position: relative;
              max-width: 620px !important;
              min-height: 100vh;
              margin: 0 auto !important;
              padding: 70px 0 120px !important;
              background: var(--reader-paper) !important;
              color: var(--reader-ink) !important;
              font-family: var(--reader-family) !important;
              font-size: var(--reader-size) !important;
              line-height: 1.8 !important;
              text-rendering: optimizeLegibility;
              -webkit-font-smoothing: antialiased;
            }
            .reader-resource {
              display: flow-root;
              max-width: 100%;
            }
            p, li, blockquote {
              line-height: 1.8 !important;
            }
            p {
              margin-top: 0 !important;
              margin-bottom: 26px !important;
            }
            h1, h2, h3, h4 {
              color: var(--reader-ink) !important;
              line-height: 1.18 !important;
              text-wrap: balance;
            }
            h1 { font-size: 2.1em !important; }
            h2 { font-size: 1.55em !important; }
            img, svg, video {
              max-width: 100% !important;
              height: auto !important;
            }
            a { color: var(--reader-moss) !important; }
            ::selection {
              background: rgba(0, 0, 0, 0.09);
            }
            ::highlight(reader-highlight-lemon) { background: rgba(244, 230, 75, .42); }
            ::highlight(reader-highlight-petal) { background: rgba(255, 143, 149, .38); }
            ::highlight(reader-highlight-ember) { background: rgba(255, 166, 74, .38); }
            ::highlight(reader-highlight-aqua) { background: rgba(76, 203, 209, .36); }
            ::highlight(reader-highlight-moss) { background: rgba(70, 212, 155, .36); }
            ::highlight(reader-search-match) { background: rgba(244, 230, 75, .48); }
            ::highlight(reader-search-active) { background: rgba(255, 153, 45, .74); }
            mark.reader-highlight {
              color: inherit;
            }
            mark.reader-highlight[data-highlight-color="lemon"] { background: rgba(244, 230, 75, .42); }
            mark.reader-highlight[data-highlight-color="petal"] { background: rgba(255, 143, 149, .38); }
            mark.reader-highlight[data-highlight-color="ember"] { background: rgba(255, 166, 74, .38); }
            mark.reader-highlight[data-highlight-color="aqua"] { background: rgba(76, 203, 209, .36); }
            mark.reader-highlight[data-highlight-color="moss"] { background: rgba(70, 212, 155, .36); }
            .reader-rewrite-line-layer {
              position: fixed;
              inset: 0 auto auto 0;
              width: 0;
              height: 0;
              pointer-events: none;
              z-index: 2147483600;
            }
            .reader-rewrite-line {
              position: absolute;
              box-sizing: border-box;
              border-radius: 4px;
              background: color-mix(in srgb, var(--reader-ink) 4%, var(--reader-paper));
              opacity: .46;
              transform: translateY(1px);
              transition:
                opacity 180ms ease,
                transform 220ms cubic-bezier(.2, .8, .2, 1),
                background-color 180ms ease;
            }
            .reader-rewrite-line::before {
              content: "";
              position: absolute;
              left: -18px;
              top: 50%;
              width: 8px;
              height: 1px;
              border-radius: 999px;
              background: var(--reader-ink);
              opacity: .16;
              transform: translateY(-50%) scaleX(.55);
              transform-origin: right center;
              transition: opacity 180ms ease, transform 220ms cubic-bezier(.2, .8, .2, 1);
            }
            .reader-rewrite-line[data-phase="active"] {
              background: color-mix(in srgb, var(--reader-ink) 8%, var(--reader-paper));
              opacity: .72;
              transform: translateY(0);
            }
            .reader-rewrite-line[data-phase="active"]::before {
              opacity: .58;
              transform: translateY(-50%) scaleX(1);
            }
            .reader-rewrite-line[data-phase="complete"] {
              background: color-mix(in srgb, var(--reader-ink) 2%, var(--reader-paper));
              opacity: .22;
              transform: translateY(-1px);
            }
            .reader-rewrite-line[data-phase="complete"]::before {
              opacity: .28;
              transform: translateY(-50%) scaleX(.72);
            }
            .reader-inline-rewrite {
              color: var(--reader-ink);
            }
            .reader-inline-rewrite-content {
              color: var(--reader-ink);
              transition: opacity 180ms ease;
            }
            .reader-inline-rewrite-actions {
              display: flex;
              align-items: center;
              gap: 17px;
              margin: 12px 0 24px;
              font-family: -apple-system, "SF Pro Text", BlinkMacSystemFont, sans-serif;
              font-size: 12px;
              font-style: italic;
              line-height: 1.35;
              letter-spacing: .01em;
            }
            .reader-inline-rewrite button {
              appearance: none;
              padding: 0;
              border: 0;
              background: transparent;
              color: var(--reader-ink);
              font: inherit;
              opacity: .45;
              cursor: default;
              transition: opacity 140ms ease;
            }
            .reader-inline-rewrite button:hover,
            .reader-inline-rewrite button:focus-visible {
              opacity: .88;
              outline: none;
            }
            .reader-inline-rewrite-status {
              display: block;
              margin: 10px 0 20px;
              font-family: -apple-system, "SF Pro Text", BlinkMacSystemFont, sans-serif;
              font-size: 12px;
              font-style: italic;
              line-height: 1.35;
              color: var(--reader-ink);
              opacity: .46;
            }
            .reader-inline-rewrite-instruction {
              display: grid;
              grid-template-columns: minmax(0, 1fr) auto auto;
              align-items: center;
              column-gap: 14px;
              row-gap: 5px;
              margin: 13px 0 25px;
              max-width: 100%;
              font-family: -apple-system, "SF Pro Text", BlinkMacSystemFont, sans-serif;
              font-size: 12px;
              font-style: italic;
              line-height: 1.35;
            }
            .reader-inline-rewrite-instruction input {
              min-width: 0;
              padding: 4px 0 6px;
              border: 0;
              border-bottom: 1px solid color-mix(in srgb, var(--reader-ink) 18%, transparent);
              border-radius: 0;
              background: transparent;
              color: var(--reader-ink);
              font: inherit;
              outline: none;
            }
            .reader-inline-rewrite-instruction input::placeholder {
              color: var(--reader-ink);
              opacity: .35;
            }
            .reader-inline-rewrite-helper {
              grid-column: 1;
              color: var(--reader-ink);
              opacity: .34;
              font-size: 11px;
            }
            @media (prefers-reduced-motion: reduce) {
              .reader-rewrite-line,
              .reader-rewrite-line::before,
              .reader-inline-rewrite-content {
                transition-duration: 1ms !important;
              }
            }
            .reader-note-leader {
              position: absolute;
              z-index: 8;
              overflow: visible;
              pointer-events: none;
            }
            .reader-note-leader path {
              fill: none;
              stroke: var(--reader-note-color);
              stroke-width: 1.15;
              stroke-linecap: round;
              opacity: .68;
              vector-effect: non-scaling-stroke;
            }
            .reader-note-marker {
              appearance: none;
              position: absolute;
              z-index: 9;
              width: 32px;
              height: 32px;
              margin: 0;
              padding: 0;
              border: 0;
              background: transparent;
              color: var(--reader-note-color);
              cursor: grab;
              touch-action: none;
              user-select: none;
              opacity: .84;
              will-change: left, top;
              transition: opacity .12s ease;
            }
            .reader-note-marker[data-dragging="true"] {
              cursor: grabbing;
              opacity: 1;
              transition: none;
            }
            .reader-note-marker::before {
              content: "";
              position: absolute;
              inset: 9px 8px 8px 9px;
              border: 1.25px solid currentColor;
              border-radius: 48% 56% 45% 58%;
              transform: rotate(-8deg);
              opacity: .82;
            }
            .reader-note-marker::after {
              content: "";
              position: absolute;
              width: 3px;
              height: 3px;
              left: 15px;
              top: 15px;
              border-radius: 50%;
              background: currentColor;
              opacity: .78;
            }
            .reader-note-marker:hover,
            .reader-note-marker:focus-visible {
              opacity: 1;
              outline: none;
            }
            .reader-note-dragging,
            .reader-note-dragging * {
              user-select: none !important;
            }
          `;
          document.documentElement.appendChild(style);

          let defaultResourceID = "text";
          var inlineRewrite = null;
          var inlineRewriteAction = null;
          var inlineRewriteTimer = null;
          var currentAnnotationItems = [];
          const resources = () => Array.from(
            document.querySelectorAll(".reader-resource[data-resource-id]")
          );
          const resourceForID = resourceID => (
            resources().find(item => item.dataset.resourceId === resourceID)
            || document.body
          );
          const resourceForNode = node => {
            const element = node.nodeType === Node.ELEMENT_NODE
              ? node
              : node.parentElement;
            return element && element.closest
              ? element.closest(".reader-resource[data-resource-id]") || document.body
              : document.body;
          };
          const resourceIDFor = root => (
            root.dataset && root.dataset.resourceId
              ? root.dataset.resourceId
              : defaultResourceID
          );
          const textNodes = root => {
            const walker = document.createTreeWalker(
              root,
              NodeFilter.SHOW_TEXT,
              {
                acceptNode(node) {
                  const parent = node.parentElement;
                  if (!parent || ["SCRIPT", "STYLE", "NOSCRIPT"].includes(parent.tagName)) {
                    return NodeFilter.FILTER_REJECT;
                  }
                  return NodeFilter.FILTER_ACCEPT;
                }
              }
            );
            const nodes = [];
            while (walker.nextNode()) nodes.push(walker.currentNode);
            return nodes;
          };
          const offsetForPosition = (container, offset, root) => {
            const range = document.createRange();
            range.selectNodeContents(root);
            try {
              range.setEnd(container, offset);
              return range.toString().length;
            } catch (_) {
              return 0;
            }
          };
          const rangeAt = (root, position, length) => {
            const nodes = textNodes(root);
            let consumed = 0;
            let startNode = null;
            let startOffset = 0;
            let endNode = null;
            let endOffset = 0;
            const endPosition = position + Math.max(length, 1);

            for (const node of nodes) {
              const next = consumed + node.data.length;
              if (!startNode && position >= consumed && position <= next) {
                startNode = node;
                startOffset = Math.min(Math.max(position - consumed, 0), node.data.length);
              }
              if (endPosition >= consumed && endPosition <= next) {
                endNode = node;
                endOffset = Math.min(Math.max(endPosition - consumed, 0), node.data.length);
                break;
              }
              consumed = next;
            }

            if (!startNode) return null;
            if (!endNode) {
              endNode = startNode;
              endOffset = Math.min(startOffset + length, startNode.data.length);
            }

            const range = document.createRange();
            range.setStart(startNode, startOffset);
            range.setEnd(endNode, endOffset);
            return range;
          };
          const findPosition = (root, exact, preferredPosition) => {
            const text = root.textContent || "";
            if (
              Number.isFinite(preferredPosition)
              && exact
              && text.slice(preferredPosition, preferredPosition + exact.length) === exact
            ) {
              return preferredPosition;
            }
            if (exact) {
              const found = text.indexOf(exact);
              if (found >= 0) return found;
            }
            return Math.max(preferredPosition || 0, 0);
          };
          const noteColor = color => ({
            lemon: "#9a8515",
            petal: "#a94f59",
            ember: "#a95d18",
            aqua: "#277c82",
            moss: "#2f7659"
          }[color] || "#6c6659");
          const clamp = (value, minimum, maximum) => (
            Math.min(Math.max(value, minimum), maximum)
          );
          const nearestRangePoint = (rects, target, bodyRect) => {
            let best = null;
            let bestDistance = Number.POSITIVE_INFINITY;
            for (const rect of rects) {
              const left = rect.left - bodyRect.left;
              const right = rect.right - bodyRect.left;
              const top = rect.top - bodyRect.top;
              const bottom = rect.bottom - bodyRect.top;
              let x = clamp(target.x, left, right);
              let y = clamp(target.y, top, bottom);
              if (
                target.x >= left && target.x <= right
                && target.y >= top && target.y <= bottom
              ) {
                const edge = [
                  { x: left, y: target.y, distance: target.x - left },
                  { x: right, y: target.y, distance: right - target.x },
                  { x: target.x, y: top, distance: target.y - top },
                  { x: target.x, y: bottom, distance: bottom - target.y }
                ].sort((a, b) => a.distance - b.distance)[0];
                x = edge.x;
                y = edge.y;
              }
              const distance = Math.hypot(target.x - x, target.y - y);
              if (distance < bestDistance) {
                best = { x, y };
                bestDistance = distance;
              }
            }
            return best;
          };
          const drawNoteLeader = (
            svg,
            rects,
            target,
            bodyRect,
            fixedSource = null
          ) => {
            const source = fixedSource || nearestRangePoint(rects, target, bodyRect);
            if (!source) return;
            const padding = 7;
            const left = Math.min(source.x, target.x) - padding;
            const top = Math.min(source.y, target.y) - padding;
            const width = Math.max(Math.abs(target.x - source.x) + padding * 2, 2);
            const height = Math.max(Math.abs(target.y - source.y) + padding * 2, 2);
            svg.style.left = `${left}px`;
            svg.style.top = `${top}px`;
            svg.style.width = `${width}px`;
            svg.style.height = `${height}px`;
            svg.setAttribute("viewBox", `0 0 ${width} ${height}`);

            const start = { x: source.x - left, y: source.y - top };
            const end = { x: target.x - left, y: target.y - top };
            const dx = end.x - start.x;
            const dy = end.y - start.y;
            const distance = Math.max(Math.hypot(dx, dy), 1);
            const nx = -dy / distance;
            const ny = dx / distance;
            const wobble = Math.min(Math.max(distance * .025, 1.5), 4.2);
            const point = (progress, offset) => ({
              x: start.x + dx * progress + nx * offset,
              y: start.y + dy * progress + ny * offset
            });
            const c1 = point(.16, wobble * .72);
            const c2 = point(.31, -wobble * .56);
            const middle = point(.5, wobble * .34);
            const c3 = point(.67, wobble * 1.04);
            const c4 = point(.84, -wobble * .68);
            svg.firstElementChild?.setAttribute(
              "d",
              `M ${start.x} ${start.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${middle.x} ${middle.y} C ${c3.x} ${c3.y}, ${c4.x} ${c4.y}, ${end.x} ${end.y}`
            );
          };
          const applyNoteMarkers = items => {
            document.querySelectorAll(
              ".reader-note-leader, .reader-note-marker"
            ).forEach(item => item.remove());

            const bodyRect = document.body.getBoundingClientRect();
            for (const item of items || []) {
              if (!item.hasNote || !item.id) continue;
              const root = resourceForID(item.resourceID);
              const position = findPosition(
                root,
                item.exact || "",
                Number(item.position)
              );
              const range = rangeAt(root, position, (item.exact || "").length);
              if (!range) continue;
              const rects = Array.from(range.getClientRects());
              const rect = rects[rects.length - 1] || range.getBoundingClientRect();
              if (!rect || (!rect.width && !rect.height)) continue;

              const y = rect.top - bodyRect.top + (rect.height / 2);
              const defaultMarkerX = Math.max(
                document.body.clientWidth + 18,
                rect.right - bodyRect.left + 28
              );
              const target = {
                x: clamp(
                  defaultMarkerX + (Number(item.noteOffsetX) || 0) * window.innerWidth,
                  -bodyRect.left + 16,
                  window.innerWidth - bodyRect.left - 16
                ),
                y: clamp(
                  y + (Number(item.noteOffsetY) || 0) * window.innerHeight,
                  16,
                  Math.max(document.body.scrollHeight - 16, 16)
                )
              };
              const color = noteColor(item.color);

              const svg = document.createElementNS(
                "http://www.w3.org/2000/svg",
                "svg"
              );
              svg.classList.add("reader-note-leader");
              svg.dataset.annotationId = item.id;
              svg.style.setProperty("--reader-note-color", color);
              const path = document.createElementNS(
                "http://www.w3.org/2000/svg",
                "path"
              );
              svg.appendChild(path);

              const marker = document.createElement("button");
              marker.type = "button";
              marker.className = "reader-note-marker";
              marker.dataset.annotationId = item.id;
              marker.setAttribute("aria-label", "Open or move note");
              marker.title = "Drag to move · Click to open";
              marker.style.left = `${target.x - 16}px`;
              marker.style.top = `${target.y - 16}px`;
              marker.style.setProperty("--reader-note-color", color);
              drawNoteLeader(svg, rects, target, bodyRect);

              let drag = null;
              let suppressClick = false;
              marker.addEventListener("pointerdown", event => {
                event.preventDefault();
                event.stopPropagation();
                try { marker.setPointerCapture(event.pointerId); } catch (_) {}
                window.getSelection()?.removeAllRanges();
                document.documentElement.classList.add("reader-note-dragging");
                marker.dataset.dragging = "true";
                drag = {
                  pointerID: event.pointerId,
                  startX: event.clientX,
                  startY: event.clientY,
                  target: { ...target },
                  source: nearestRangePoint(rects, target, bodyRect),
                  moved: false
                };
              });
              marker.addEventListener("pointermove", event => {
                if (!drag || drag.pointerID !== event.pointerId) return;
                event.preventDefault();
                event.stopPropagation();
                const distance = Math.hypot(
                  event.clientX - drag.startX,
                  event.clientY - drag.startY
                );
                if (!drag.moved && distance <= 5) return;
                drag.moved = true;
                const next = {
                  x: clamp(
                    event.clientX - bodyRect.left,
                    -bodyRect.left + 16,
                    window.innerWidth - bodyRect.left - 16
                  ),
                  y: clamp(
                    event.clientY - bodyRect.top,
                    16,
                    Math.max(document.body.scrollHeight - 16, 16)
                  )
                };
                drag.target = next;
                marker.style.left = `${next.x - 16}px`;
                marker.style.top = `${next.y - 16}px`;
                drawNoteLeader(svg, rects, next, bodyRect, drag.source);
              });
              marker.addEventListener("pointerup", event => {
                if (!drag || drag.pointerID !== event.pointerId) return;
                event.preventDefault();
                event.stopPropagation();
                try { marker.releasePointerCapture(event.pointerId); } catch (_) {}
                delete marker.dataset.dragging;
                document.documentElement.classList.remove("reader-note-dragging");
                const finished = drag;
                drag = null;
                if (finished.moved) {
                  suppressClick = true;
                  drawNoteLeader(svg, rects, finished.target, bodyRect);
                  window.webkit?.messageHandlers.readerAnnotationNotePlacement?.postMessage({
                    id: item.id,
                    horizontalOffset: (finished.target.x - defaultMarkerX)
                      / Math.max(window.innerWidth, 1),
                    verticalOffset: (finished.target.y - y)
                      / Math.max(window.innerHeight, 1)
                  });
                }
              });
              marker.addEventListener("pointercancel", () => {
                if (drag?.moved) {
                  marker.style.left = `${target.x - 16}px`;
                  marker.style.top = `${target.y - 16}px`;
                  drawNoteLeader(svg, rects, target, bodyRect);
                }
                drag = null;
                delete marker.dataset.dragging;
                document.documentElement.classList.remove("reader-note-dragging");
              });
              marker.addEventListener("click", event => {
                event.preventDefault();
                event.stopPropagation();
                if (suppressClick) {
                  suppressClick = false;
                  return;
                }
                const markerRect = marker.getBoundingClientRect();
                window.webkit?.messageHandlers.readerAnnotationNote?.postMessage({
                  id: item.id,
                  x: markerRect.left + markerRect.width / 2,
                  y: markerRect.top + markerRect.height / 2
                });
              });
              document.body.append(svg, marker);
            }
          };
          const scrollToElement = (element, animated = true) => {
            if (!element) return;
            const rect = element.getBoundingClientRect();
            window.scrollTo({
              top: window.scrollY + rect.top - 54,
              behavior: animated ? "smooth" : "instant"
            });
          };
          const currentResource = () => {
            const all = resources();
            if (!all.length) return document.body;
            const threshold = Math.max(window.innerHeight * 0.28, 110);
            let current = all[0];
            for (const item of all) {
              if (item.getBoundingClientRect().top <= threshold) {
                current = item;
              } else {
                break;
              }
            }
            return current;
          };
          const clearRewriteTimer = () => {
            if (inlineRewriteTimer) {
              window.clearInterval(inlineRewriteTimer);
              inlineRewriteTimer = null;
            }
          };
          const removeRewriteLines = () => {
            document.querySelectorAll(".reader-rewrite-line-layer").forEach(layer => layer.remove());
          };
          const uniqueLineRects = range => {
            const rects = Array.from(range.getClientRects())
              .filter(rect => rect.width > 1 && rect.height > 1)
              .sort((first, second) => first.top - second.top || first.left - second.left);
            const lines = [];
            for (const rect of rects) {
              const existing = lines.find(line => Math.abs(line.top - rect.top) < 2);
              if (existing) {
                const right = Math.max(existing.right, rect.right);
                existing.left = Math.min(existing.left, rect.left);
                existing.right = right;
                existing.width = right - existing.left;
                existing.height = Math.max(existing.height, rect.height);
              } else {
                lines.push({
                  left: rect.left,
                  right: rect.right,
                  top: rect.top,
                  width: rect.width,
                  height: rect.height
                });
              }
            }
            return lines;
          };
          const lineLayerForRange = (range, mode) => {
            removeRewriteLines();
            const lines = uniqueLineRects(range);
            if (!lines.length) return null;
            const layer = document.createElement("div");
            layer.className = "reader-rewrite-line-layer";
            layer.dataset.mode = mode;
            lines.forEach((rect, index) => {
              const line = document.createElement("div");
              line.className = "reader-rewrite-line";
              line.dataset.phase = index === 0 ? "active" : "waiting";
              line.style.left = `${rect.left}px`;
              line.style.top = `${rect.top + 1}px`;
              line.style.width = `${rect.width}px`;
              line.style.height = `${Math.max(rect.height - 2, 2)}px`;
              layer.appendChild(line);
            });
            document.body.appendChild(layer);
            return layer;
          };
          const animateLoadingLines = layer => {
            clearRewriteTimer();
            const lines = Array.from(layer.children);
            let active = 0;
            inlineRewriteTimer = window.setInterval(() => {
              if (!layer.isConnected || !lines.length) {
                clearRewriteTimer();
                return;
              }
              active = Math.min(active + 1, lines.length - 1);
              lines.forEach((line, index) => {
                line.dataset.phase = index < active
                  ? "complete"
                  : index === active ? "active" : "waiting";
              });
            }, 360);
          };
          const queueRewriteAction = (action, instruction) => {
            inlineRewriteAction = { action, instruction: instruction || null };
          };
          const actionButton = (title, action) => {
            const button = document.createElement("button");
            button.type = "button";
            button.textContent = title;
            button.addEventListener("click", action);
            return button;
          };
          const renderRewriteActions = () => {
            if (!inlineRewrite || !inlineRewrite.wrapper) return;
            inlineRewrite.wrapper.querySelectorAll(
              ".reader-inline-rewrite-actions, .reader-inline-rewrite-status, .reader-inline-rewrite-instruction"
            ).forEach(item => item.remove());

            const actions = document.createElement("span");
            actions.className = "reader-inline-rewrite-actions";
            actions.appendChild(actionButton("original", () => {
              if (!inlineRewrite) return;
              const showingOriginal = inlineRewrite.content.dataset.showingOriginal === "true";
              inlineRewrite.content.textContent = showingOriginal
                ? inlineRewrite.rewriteText
                : inlineRewrite.originalText;
              inlineRewrite.content.dataset.showingOriginal = showingOriginal ? "false" : "true";
            }));
            actions.appendChild(actionButton("rewrite again…", () => {
              if (!inlineRewrite) return;
              actions.replaceWith(renderRewriteInstruction());
            }));
            actions.appendChild(actionButton("dismiss", () => queueRewriteAction("dismiss")));
            inlineRewrite.wrapper.appendChild(actions);
          };
          const renderRewriteInstruction = () => {
            const form = document.createElement("form");
            form.className = "reader-inline-rewrite-instruction";
            const input = document.createElement("input");
            input.type = "text";
            input.autocomplete = "off";
            input.spellcheck = true;
            input.placeholder = "how should this change?";
            input.setAttribute("aria-label", "One-time rewrite instruction");
            const rewrite = actionButton("rewrite", () => {});
            rewrite.type = "submit";
            const cancel = actionButton("cancel", () => renderRewriteActions());
            const helper = document.createElement("span");
            helper.className = "reader-inline-rewrite-helper";
            helper.textContent = "this rewrite only";
            form.append(input, rewrite, cancel, helper);
            form.addEventListener("submit", event => {
              event.preventDefault();
              const instruction = input.value.trim();
              if (!instruction) return;
              queueRewriteAction("rewrite", instruction);
            });
            window.setTimeout(() => input.focus(), 30);
            return form;
          };
          const restoreInlineRewrite = () => {
            clearRewriteTimer();
            removeRewriteLines();
            if (!inlineRewrite) return;
            if (inlineRewrite.wrapper && inlineRewrite.wrapper.isConnected) {
              if (inlineRewrite.originalFragment) {
                inlineRewrite.wrapper.replaceWith(inlineRewrite.originalFragment);
              } else {
                inlineRewrite.wrapper.remove();
              }
            }
            inlineRewrite = null;
            window.getSelection()?.removeAllRanges();
          };

          window.ReaderRuntime = {
            setDefaultResourceID(resourceID) {
              defaultResourceID = resourceID || "text";
            },

            setScale(scale) {
              document.documentElement.style.setProperty("--reader-scale", String(scale));
            },

            progression() {
              const maximum = Math.max(
                document.documentElement.scrollHeight - window.innerHeight,
                1
              );
              return Math.min(Math.max(window.scrollY / maximum, 0), 1);
            },

            currentLocationJSON() {
              const root = currentResource();
              let position = 0;
              if (document.caretRangeFromPoint) {
                const range = document.caretRangeFromPoint(
                  Math.max(window.innerWidth / 2, 1),
                  Math.max(Math.min(window.innerHeight * 0.25, window.innerHeight - 1), 1)
                );
                if (range && root.contains(range.startContainer)) {
                  position = offsetForPosition(
                    range.startContainer,
                    range.startOffset,
                    root
                  );
                }
              }
              return JSON.stringify({
                resourceID: resourceIDFor(root),
                position,
                progression: this.progression()
              });
            },

            selectionJSON() {
              const selection = window.getSelection();
              if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
              const range = selection.getRangeAt(0);
              const exact = selection.toString();
              if (!exact.trim()) return null;
              const root = resourceForNode(range.startContainer);
              if (!root.contains(range.endContainer)) return null;
              const start = offsetForPosition(
                range.startContainer,
                range.startOffset,
                root
              );
              const text = root.textContent || "";
              const rect = range.getBoundingClientRect();
              return JSON.stringify({
                resourceID: resourceIDFor(root),
                exact,
                prefix: text.slice(Math.max(0, start - 48), start),
                suffix: text.slice(start + exact.length, start + exact.length + 48),
                start,
                progression: this.progression(),
                viewportX: rect.left + (rect.width / 2),
                viewportY: rect.top
              });
            },

            beginInlineRewrite(expectedExact) {
              restoreInlineRewrite();
              const selection = window.getSelection();
              if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return false;
              const range = selection.getRangeAt(0).cloneRange();
              const exact = selection.toString();
              if (!exact.trim() || exact !== expectedExact) return false;
              const root = resourceForNode(range.startContainer);
              if (!root.contains(range.endContainer)) return false;

              const layer = lineLayerForRange(range, "loading");
              if (!layer) return false;
              inlineRewrite = {
                range,
                originalText: exact,
                originalFragment: null,
                rewriteText: "",
                wrapper: null,
                content: null
              };
              animateLoadingLines(layer);
              selection.removeAllRanges();
              return true;
            },

            showInlineRewrite(text) {
              if (!inlineRewrite || !String(text || "").trim()) return;
              clearRewriteTimer();
              removeRewriteLines();
              if (!inlineRewrite.range && inlineRewrite.content) {
                inlineRewrite.rewriteText = String(text).trim();
                inlineRewrite.content.textContent = inlineRewrite.rewriteText;
                inlineRewrite.content.dataset.showingOriginal = "false";
                const updatedRange = document.createRange();
                updatedRange.selectNodeContents(inlineRewrite.content);
                const updatedLayer = lineLayerForRange(updatedRange, "reveal");
                renderRewriteActions();
                if (!updatedLayer) return;
                const updatedLines = Array.from(updatedLayer.children);
                updatedLines.forEach(line => { line.dataset.phase = "active"; });
                updatedLines.forEach((line, index) => {
                  window.setTimeout(() => {
                    line.style.opacity = "0";
                    line.style.transform = "translateY(-2px)";
                    if (index === updatedLines.length - 1) {
                      window.setTimeout(() => updatedLayer.remove(), 220);
                    }
                  }, 90 + index * 165);
                });
                return;
              }
              if (!inlineRewrite.range) return;
              const range = inlineRewrite.range;
              const originalFragment = range.extractContents();
              const wrapper = document.createElement("span");
              wrapper.className = "reader-inline-rewrite";
              const content = document.createElement("span");
              content.className = "reader-inline-rewrite-content";
              content.textContent = String(text).trim();
              content.dataset.showingOriginal = "false";
              wrapper.appendChild(content);
              range.insertNode(wrapper);
              inlineRewrite.originalFragment = originalFragment;
              inlineRewrite.rewriteText = String(text).trim();
              inlineRewrite.wrapper = wrapper;
              inlineRewrite.content = content;
              inlineRewrite.range = null;

              const revealRange = document.createRange();
              revealRange.selectNodeContents(content);
              const revealLayer = lineLayerForRange(revealRange, "reveal");
              renderRewriteActions();
              if (!revealLayer) return;
              const lines = Array.from(revealLayer.children);
              lines.forEach(line => { line.dataset.phase = "active"; });
              lines.forEach((line, index) => {
                window.setTimeout(() => {
                  line.style.opacity = "0";
                  line.style.transform = "translateY(-2px)";
                  if (index === lines.length - 1) {
                    window.setTimeout(() => revealLayer.remove(), 220);
                  }
                }, 90 + index * 165);
              });
            },

            showInlineRewriteFailure(message) {
              clearRewriteTimer();
              removeRewriteLines();
              if (!inlineRewrite) return;
              const status = document.createElement("span");
              status.className = "reader-inline-rewrite-status";
              status.textContent = String(message || "rewrite unavailable");
              const retry = actionButton("retry", () => queueRewriteAction("retry"));
              status.append("  ", retry);
              const dismiss = actionButton("dismiss", () => queueRewriteAction("dismiss"));
              status.append("  ", dismiss);
              const range = inlineRewrite.range;
              if (range) {
                const marker = document.createElement("span");
                marker.className = "reader-inline-rewrite";
                marker.appendChild(status);
                const markerRange = range.cloneRange();
                markerRange.collapse(false);
                markerRange.insertNode(marker);
                inlineRewrite.wrapper = marker;
              } else if (inlineRewrite.wrapper) {
                inlineRewrite.wrapper.appendChild(status);
              }
            },

            restartInlineRewriteLoading() {
              if (!inlineRewrite) return false;
              if (inlineRewrite.wrapper) {
                inlineRewrite.wrapper.querySelectorAll(
                  ".reader-inline-rewrite-actions, .reader-inline-rewrite-status, .reader-inline-rewrite-instruction"
                ).forEach(item => item.remove());
              }
              const range = inlineRewrite.range || (() => {
                if (!inlineRewrite.content) return null;
                const current = document.createRange();
                current.selectNodeContents(inlineRewrite.content);
                return current;
              })();
              if (!range) return false;
              const layer = lineLayerForRange(range, "loading");
              if (!layer) return false;
              animateLoadingLines(layer);
              return true;
            },

            takeInlineRewriteActionJSON() {
              if (!inlineRewriteAction) return null;
              const action = inlineRewriteAction;
              inlineRewriteAction = null;
              return JSON.stringify(action);
            },

            dismissInlineRewrite() {
              restoreInlineRewrite();
            },

            navigate(position, anchor, resourceID, animated = true) {
              const root = resourceForID(resourceID);
              const exact = anchor && anchor.exact ? anchor.exact : "";
              const resolved = findPosition(root, exact, position);
              const range = rangeAt(root, resolved, exact.length || 1);
              if (!range) {
                scrollToElement(root, animated);
                return;
              }
              const rect = range.getBoundingClientRect();
              window.scrollTo({
                top: window.scrollY + rect.top - Math.max((window.innerHeight - rect.height) / 3, 80),
                behavior: animated ? "smooth" : "instant"
              });
            },

            navigateToSection(resourceID, fragment) {
              const root = resourceForID(resourceID);
              const fragmentTarget = fragment
                ? Array.from(root.querySelectorAll("[id]")).find(
                    item => item.id === fragment
                  )
                : null;
              scrollToElement(
                fragmentTarget && root.contains(fragmentTarget)
                  ? fragmentTarget
                  : root
              );
            },

            applyHighlights(items) {
              currentAnnotationItems = items || [];
              applyNoteMarkers(currentAnnotationItems);
              const rangesByColor = new Map();
              for (const item of items || []) {
                const root = resourceForID(item.resourceID);
                const position = findPosition(
                  root,
                  item.exact || "",
                  Number(item.position)
                );
                const range = rangeAt(root, position, (item.exact || "").length);
                if (range) {
                  const color = ["lemon", "petal", "ember", "aqua", "moss"].includes(item.color)
                    ? item.color
                    : "lemon";
                  const ranges = rangesByColor.get(color) || [];
                  ranges.push(range);
                  rangesByColor.set(color, ranges);
                }
              }

              if (window.CSS && CSS.highlights && window.Highlight) {
                for (const color of ["lemon", "petal", "ember", "aqua", "moss"]) {
                  const name = `reader-highlight-${color}`;
                  CSS.highlights.delete(name);
                  const ranges = rangesByColor.get(color) || [];
                  if (ranges.length) {
                    CSS.highlights.set(name, new Highlight(...ranges));
                  }
                }
                return;
              }

              document.querySelectorAll("mark.reader-highlight").forEach(mark => {
                mark.replaceWith(...mark.childNodes);
              });
              for (const [color, ranges] of rangesByColor) {
                for (const range of ranges.reverse()) {
                  try {
                    const mark = document.createElement("mark");
                    mark.className = "reader-highlight";
                    mark.dataset.highlightColor = color;
                    range.surroundContents(mark);
                  } catch (_) {}
                }
              }
            },

            refreshNoteMarkers() {
              applyNoteMarkers(currentAnnotationItems);
            },

            applySearchResults(items) {
              this.searchResultRanges = [];
              var activeIndex = null;
              for (const [index, item] of (items || []).entries()) {
                const root = resourceForID(item.resourceID);
                const position = findPosition(
                  root,
                  item.exact || "",
                  Number(item.position)
                );
                const range = rangeAt(root, position, (item.exact || "").length);
                if (!range) continue;
                this.searchResultRanges[index] = range;
                if (item.active) activeIndex = index;
              }

              if (window.CSS && CSS.highlights && window.Highlight) {
                CSS.highlights.delete("reader-search-match");
                CSS.highlights.delete("reader-search-active");
                this.searchMatchHighlight = new Highlight(
                  ...this.searchResultRanges.filter(Boolean)
                );
                this.searchActiveHighlight = new Highlight();
                this.activeSearchResultIndex = null;
                this.activateSearchResult(activeIndex);
                if (this.searchResultRanges.some(Boolean)) {
                  CSS.highlights.set("reader-search-match", this.searchMatchHighlight);
                  CSS.highlights.set("reader-search-active", this.searchActiveHighlight);
                }
              }
            },

            activateSearchResult(index) {
              const previousRange = this.searchResultRanges
                ? this.searchResultRanges[this.activeSearchResultIndex]
                : null;
              if (previousRange && this.searchActiveHighlight && this.searchMatchHighlight) {
                this.searchActiveHighlight.delete(previousRange);
                this.searchMatchHighlight.add(previousRange);
              }
              const nextRange = this.searchResultRanges
                ? this.searchResultRanges[index]
                : null;
              if (nextRange && this.searchActiveHighlight && this.searchMatchHighlight) {
                this.searchMatchHighlight.delete(nextRange);
                this.searchActiveHighlight.add(nextRange);
              }
              this.activeSearchResultIndex = nextRange ? index : null;
            }
          };
          let noteLayoutFrame = null;
          window.addEventListener("resize", () => {
            if (noteLayoutFrame) cancelAnimationFrame(noteLayoutFrame);
            noteLayoutFrame = requestAnimationFrame(() => {
              window.ReaderRuntime?.refreshNoteMarkers();
            });
          });
        })();
        """#
}

enum EPUBContinuousDocumentBuilder {
    private struct Fragment {
        let body: String
        let bodyClasses: String
        let direction: String?
        let language: String?
        let stylesheets: [URL]
        let inlineStyles: [String]
    }

    static func build(publication: EPUBPublication) throws -> URL {
        let destinations = Dictionary(
            uniqueKeysWithValues: publication.spine.enumerated().map {
                index,
                resource in
                (
                    resource.fileURL.standardizedFileURL.path,
                    "reader-resource-\(index)"
                )
            }
        )
        var fragments: [Fragment] = []

        for resource in publication.spine {
            let parser = EPUBContinuousFragmentParser(
                resourceURL: resource.fileURL,
                spineDestinations: destinations
            )
            let parsed = parser.parse()
            let body = parsed.body.isEmpty
                ? fallbackBody(for: resource.fileURL)
                : parsed.body
            fragments.append(
                Fragment(
                    body: body,
                    bodyClasses: parsed.bodyClasses,
                    direction: parsed.direction,
                    language: parsed.language,
                    stylesheets: parsed.stylesheets,
                    inlineStyles: parsed.inlineStyles
                )
            )
        }

        var seenStylesheets: Set<String> = []
        let stylesheetMarkup: String = fragments
            .flatMap(\.stylesheets)
            .filter {
                seenStylesheets.insert($0.absoluteString).inserted
            }
            .map { stylesheet -> String in
                #"<link rel="stylesheet" href="\#(escapeAttribute(stylesheet.absoluteString))"/>"#
            }
            .joined(separator: "\n")
        let inlineStyleMarkup: String = fragments
            .flatMap(\.inlineStyles)
            .map { value -> String in "<style>\(value)</style>" }
            .joined(separator: "\n")
        let bodyMarkup: String = zip(publication.spine.indices, fragments)
            .map { index, fragment -> String in
                let resource = publication.spine[index]
                let classes: String = ["reader-resource", fragment.bodyClasses]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let direction: String = fragment.direction.map {
                    #" dir="\#(escapeAttribute($0))""#
                } ?? ""
                let language: String = fragment.language.map {
                    #" lang="\#(escapeAttribute($0))""#
                } ?? ""

                return """
                <section
                  id="reader-resource-\(index)"
                  class="\(escapeAttribute(classes))"
                  data-resource-id="\(escapeAttribute(resource.id))"\(direction)\(language)
                >
                \(fragment.body)
                </section>
                """
            }
            .joined(separator: "\n")
        let html: String = """
        <!doctype html>
        <html
          xmlns="http://www.w3.org/1999/xhtml"
          xmlns:epub="http://www.idpf.org/2007/ops"
          xmlns:xlink="http://www.w3.org/1999/xlink"
        >
        <head>
          <meta charset="utf-8"/>
          <title>\(escapeHTML(publication.title))</title>
          \(stylesheetMarkup)
          \(inlineStyleMarkup)
        </head>
        <body>
        \(bodyMarkup)
        </body>
        </html>
        """
        let generatedDirectory = publication.rootDirectory.appending(
            path: "ReaderGenerated",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: generatedDirectory,
            withIntermediateDirectories: true
        )
        let documentURL = generatedDirectory.appending(
            path: "continuous.html",
            directoryHint: .notDirectory
        )
        try Data(html.utf8).write(to: documentURL, options: .atomic)
        return documentURL
    }

    private static func fallbackBody(for url: URL) -> String {
        let text = XHTMLTextExtractor.extract(from: url).text
        let paragraphs: String = text
            .components(separatedBy: "\n\n")
            .filter { !$0.isEmpty }
            .map { value -> String in "<p>\(escapeHTML(value))</p>" }
            .joined(separator: "\n")
        return paragraphs
    }

    fileprivate static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    fileprivate static func escapeAttribute(_ value: String) -> String {
        escapeHTML(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private final class EPUBContinuousFragmentParser: NSObject, XMLParserDelegate {
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    struct Result {
        let body: String
        let bodyClasses: String
        let direction: String?
        let language: String?
        let stylesheets: [URL]
        let inlineStyles: [String]
    }

    private let resourceURL: URL
    private let spineDestinations: [String: String]
    private var body = ""
    private var bodyClasses = ""
    private var direction: String?
    private var language: String?
    private var stylesheets: [URL] = []
    private var inlineStyles: [String] = []
    private var activeInlineStyle: String?
    private var isInsideBody = false
    private var ignoredDepth = 0

    init(resourceURL: URL, spineDestinations: [String: String]) {
        self.resourceURL = resourceURL
        self.spineDestinations = spineDestinations
    }

    func parse() -> Result {
        guard let data = try? Data(contentsOf: resourceURL, options: .mappedIfSafe) else {
            return result
        }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return result
    }

    private var result: Result {
        Result(
            body: body,
            bodyClasses: bodyClasses,
            direction: direction,
            language: language,
            stylesheets: stylesheets,
            inlineStyles: inlineStyles
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        let localName = elementName.split(separator: ":").last.map(String.init)
            ?? elementName

        if !isInsideBody {
            if localName == "link" {
                captureStylesheet(attributeDict)
            } else if localName == "style" {
                activeInlineStyle = ""
            } else if localName == "body" {
                isInsideBody = true
                bodyClasses = attributeDict["class"] ?? ""
                direction = attributeDict["dir"]
                language = attributeDict["lang"] ?? attributeDict["xml:lang"]
            }
            return
        }

        if ["script", "iframe", "object", "embed"].contains(localName) {
            ignoredDepth += 1
            return
        }
        guard ignoredDepth == 0 else {
            ignoredDepth += 1
            return
        }

        let attributes: String = attributeDict
            .filter { key, _ in
                !key.lowercased().hasPrefix("on")
                    && key != "xmlns"
                    && !key.hasPrefix("xmlns:")
            }
            .sorted { $0.key < $1.key }
            .map { key, value -> String in
                let rewritten = rewrite(value: value, for: key)
                return #"\#(key)="\#(EPUBContinuousDocumentBuilder.escapeAttribute(rewritten))""#
            }
            .joined(separator: " ")
        let close = Self.voidElements.contains(localName) ? "/>" : ">"
        body += attributes.isEmpty
            ? "<\(name)\(close)"
            : "<\(name) \(attributes)\(close)"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeInlineStyle != nil, !isInsideBody {
            activeInlineStyle? += string
        } else if isInsideBody, ignoredDepth == 0 {
            body += EPUBContinuousDocumentBuilder.escapeHTML(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCDATA CDATABlock: Data
    ) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            return
        }
        if activeInlineStyle != nil, !isInsideBody {
            activeInlineStyle? += string
        } else if isInsideBody, ignoredDepth == 0 {
            body += EPUBContinuousDocumentBuilder.escapeHTML(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        let localName = elementName.split(separator: ":").last.map(String.init)
            ?? elementName

        if !isInsideBody {
            if localName == "style", let activeInlineStyle {
                inlineStyles.append(activeInlineStyle)
                self.activeInlineStyle = nil
            }
            return
        }

        if localName == "body" {
            isInsideBody = false
            return
        }
        if ignoredDepth > 0 {
            ignoredDepth -= 1
            return
        }
        if Self.voidElements.contains(localName) {
            return
        }
        body += "</\(name)>"
    }

    private func captureStylesheet(_ attributes: [String: String]) {
        guard
            attributes["rel"]?
                .split(whereSeparator: \.isWhitespace)
                .contains(where: { $0.lowercased() == "stylesheet" }) == true,
            let href = attributes["href"],
            let url = resolvedURL(for: href)
        else {
            return
        }
        stylesheets.append(url)
    }

    private func rewrite(value: String, for attribute: String) -> String {
        let lowercased = attribute.lowercased()
        if lowercased == "href" || lowercased == "xlink:href" {
            guard !value.hasPrefix("#"), let resolved = resolvedURL(for: value) else {
                return value
            }
            guard resolved.isFileURL else { return value }

            var components = URLComponents(
                url: resolved,
                resolvingAgainstBaseURL: false
            )
            let fragment = components?.fragment?.removingPercentEncoding
            components?.fragment = nil
            components?.query = nil
            if
                let path = components?.url?.standardizedFileURL.path,
                let destination = spineDestinations[path]
            {
                return fragment?.nilIfEmpty.map { "#\($0)" }
                    ?? "#\(destination)"
            }
            return resolved.absoluteString
        }

        if ["src", "poster"].contains(lowercased) {
            return resolvedURL(for: value)?.absoluteString ?? value
        }

        if lowercased == "srcset" {
            return value
                .split(separator: ",")
                .map { candidate in
                    let pieces = candidate
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(
                            maxSplits: 1,
                            whereSeparator: \.isWhitespace
                        )
                    guard let first = pieces.first else { return "" }
                    let url = resolvedURL(for: String(first))?.absoluteString
                        ?? String(first)
                    return pieces.count > 1
                        ? "\(url) \(pieces[1])"
                        : url
                }
                .joined(separator: ", ")
        }

        return value
    }

    private func resolvedURL(for value: String) -> URL? {
        URL(
            string: value,
            relativeTo: resourceURL
                .deletingLastPathComponent()
                .appending(path: "", directoryHint: .isDirectory)
        )?.absoluteURL
    }
}

struct WebKitSurfaceView: NSViewRepresentable {
    let adapter: WebKitReadingAdapter

    func makeCoordinator() -> Coordinator {
        Coordinator(adapter: adapter)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = adapter.webView
        context.coordinator.observeMagnification(in: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(
        _ nsView: WKWebView,
        coordinator: Coordinator
    ) {
        coordinator.stopObservingMagnification()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let adapter: WebKitReadingAdapter
        private var magnificationMonitor: Any?

        init(adapter: WebKitReadingAdapter) {
            self.adapter = adapter
        }

        func observeMagnification(in webView: WKWebView) {
            stopObservingMagnification()
            magnificationMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .magnify
            ) { [weak self, weak webView] event in
                guard
                    let self,
                    let webView,
                    event.window === webView.window
                else {
                    return event
                }

                let location = webView.convert(
                    event.locationInWindow,
                    from: nil
                )
                guard webView.bounds.contains(location) else {
                    return event
                }

                DispatchQueue.main.async { [weak self] in
                    self?.adapter.didMagnifyNatively()
                }
                return event
            }
        }

        func stopObservingMagnification() {
            guard let magnificationMonitor else { return }
            NSEvent.removeMonitor(magnificationMonitor)
            self.magnificationMonitor = nil
        }
    }
}

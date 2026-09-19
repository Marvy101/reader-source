import AppKit
import PDFKit
import SwiftUI

private final class ReaderPDFView: PDFView {
    var onAnnotationNoteRequested: ((ReaderAnnotationNoteRequest) -> Void)?
    var onAnnotationNotePlacementChanged: ((ReaderAnnotationNotePlacementRequest) -> Void)?
    private lazy var noteOverlay = ReaderPDFNoteMarkerOverlay(pdfView: self)
    private weak var observedClipView: NSClipView?
    private var draggedNote: (
        annotation: ReaderPDFMarginNoteAnnotation,
        page: PDFPage,
        startPoint: CGPoint,
        moved: Bool
    )?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installNoteOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installNoteOverlay()
    }

    override func layout() {
        super.layout()
        noteOverlay.frame = bounds
        addSubview(noteOverlay, positioned: .above, relativeTo: nil)
        observeDocumentScrolling()
        noteOverlay.needsDisplay = true
    }

    func displayMarginNotes(_ notes: [(page: PDFPage, annotation: ReaderPDFMarginNoteAnnotation)]) {
        observeDocumentScrolling()
        noteOverlay.display(notes)
    }

    func refreshMarginNotes() {
        noteOverlay.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let note = noteOverlay.note(at: point) {
            note.annotation.beginMarkerMove()
            draggedNote = (
                annotation: note.annotation,
                page: note.page,
                startPoint: point,
                moved: false
            )
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = draggedNote else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        drag.moved = drag.moved || hypot(
            point.x - drag.startPoint.x,
            point.y - drag.startPoint.y
        ) > 5
        let pagePoint = convert(point, to: drag.page)
        // The white margin around a PDF varies with the window and zoom. Keep
        // the complete ring inside the actual reader viewport, not a fixed
        // distance from the PDF crop box.
        let visiblePageBounds = convert(
            bounds.insetBy(dx: 12, dy: 12),
            to: drag.page
        ).standardized
        drag.annotation.moveMarker(to: pagePoint, within: visiblePageBounds)
        draggedNote = drag
        noteOverlay.needsDisplay = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = draggedNote else {
            super.mouseUp(with: event)
            return
        }
        draggedNote = nil
        drag.annotation.endMarkerMove()
        noteOverlay.needsDisplay = true
        needsDisplay = true
        let point = convert(event.locationInWindow, from: nil)
        if drag.moved {
            onAnnotationNotePlacementChanged?(
                ReaderAnnotationNotePlacementRequest(
                    annotationID: drag.annotation.annotationID,
                    placement: drag.annotation.placement
                )
            )
        } else {
            onAnnotationNoteRequested?(
                ReaderAnnotationNoteRequest(
                    annotationID: drag.annotation.annotationID,
                    viewportPoint: ReaderViewportPoint(
                        x: point.x,
                        y: isFlipped ? point.y : bounds.height - point.y
                    )
                )
            )
        }
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        noteOverlay.needsDisplay = true
    }

    private func installNoteOverlay() {
        noteOverlay.frame = bounds
        noteOverlay.autoresizingMask = [.width, .height]
        addSubview(noteOverlay, positioned: .above, relativeTo: nil)
    }

    private func observeDocumentScrolling() {
        guard let clipView = documentView?.enclosingScrollView?.contentView else { return }
        observeClipView(clipView)
    }

    private func observeClipView(_ clipView: NSClipView) {
        guard observedClipView !== clipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func documentDidScroll() {
        noteOverlay.needsDisplay = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private final class ReaderPDFNoteMarkerOverlay: NSView {
    private weak var pdfView: ReaderPDFView?
    private var notes: [(page: PDFPage, annotation: ReaderPDFMarginNoteAnnotation)] = []

    init(pdfView: ReaderPDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool {
        pdfView?.isFlipped ?? true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // ReaderPDFView performs the marker hit test so this visual-only layer
        // never blocks text selection away from a marker.
        nil
    }

    func display(_ notes: [(page: PDFPage, annotation: ReaderPDFMarginNoteAnnotation)]) {
        self.notes = notes
        needsDisplay = true
    }

    func note(at point: CGPoint) -> (page: PDFPage, annotation: ReaderPDFMarginNoteAnnotation)? {
        guard let pdfView else { return nil }
        let overlayPoint = convert(point, from: pdfView)
        return notes.reversed().first { note in
            let markerCenter = self.point(note.annotation.markerCenter, on: note.page)
            return hypot(
                overlayPoint.x - markerCenter.x,
                overlayPoint.y - markerCenter.y
            ) <= 22
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for note in notes {
            let start = point(note.annotation.currentLeaderStart, on: note.page)
            let markerCenter = point(note.annotation.markerCenter, on: note.page)
            drawLeader(from: start, to: markerCenter, color: note.annotation.overlayColor)
            drawMarker(at: markerCenter, color: note.annotation.overlayColor)
        }
    }

    private func point(_ pagePoint: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return .zero }
        let pdfPoint = pdfView.convert(pagePoint, from: page)
        return convert(pdfPoint, from: pdfView)
    }

    private func drawLeader(from start: CGPoint, to end: CGPoint, color: NSColor) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = max(hypot(dx, dy), 1)
        let normal = CGPoint(x: -dy / distance, y: dx / distance)
        let wobble = min(max(distance * 0.025, 1.5), 4.2)
        func point(_ progress: CGFloat, _ offset: CGFloat) -> CGPoint {
            CGPoint(
                x: start.x + dx * progress + normal.x * offset,
                y: start.y + dy * progress + normal.y * offset
            )
        }

        let leader = NSBezierPath()
        leader.move(to: start)
        leader.curve(
            to: point(0.5, wobble * 0.34),
            controlPoint1: point(0.16, wobble * 0.72),
            controlPoint2: point(0.31, -wobble * 0.56)
        )
        leader.curve(
            to: end,
            controlPoint1: point(0.67, wobble * 1.04),
            controlPoint2: point(0.84, -wobble * 0.68)
        )
        color.setStroke()
        leader.lineWidth = 1.25
        leader.lineCapStyle = .round
        leader.stroke()
    }

    private func drawMarker(at center: CGPoint, color: NSColor) {
        color.setStroke()
        let ring = NSBezierPath(
            ovalIn: CGRect(x: center.x - 7.5, y: center.y - 7.5, width: 15, height: 15)
        )
        ring.lineWidth = 1.25
        ring.stroke()

        color.setFill()
        NSBezierPath(
            ovalIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)
        ).fill()
    }
}

final class ReaderPDFMarginNoteAnnotation: PDFAnnotation {
    let annotationID: UUID
    private let highlightBounds: CGRect
    private let pageBounds: CGRect
    private let defaultMarkerCenter: CGPoint
    private(set) var markerCenter: CGPoint
    private let inkColor: NSColor
    private var fixedLeaderStart: CGPoint?

    var markerBounds: CGRect {
        CGRect(
            x: markerCenter.x - 13,
            y: markerCenter.y - 13,
            width: 26,
            height: 26
        )
    }

    var placement: ReaderNotePlacement {
        ReaderNotePlacement(
            horizontalOffset: (markerCenter.x - defaultMarkerCenter.x)
                / max(pageBounds.width, 1),
            verticalOffset: (markerCenter.y - defaultMarkerCenter.y)
                / max(pageBounds.height, 1)
        )
    }

    var currentLeaderStart: CGPoint { leaderStart }
    var overlayColor: NSColor { inkColor }

    static func defaultMarkerCenter(
        highlightBounds: CGRect,
        pageBounds: CGRect
    ) -> CGPoint {
        let margin: CGFloat = 20
        let leftMarkerX = pageBounds.minX + margin
        let rightMarkerX = pageBounds.maxX - margin
        let leftRun = max(highlightBounds.minX - leftMarkerX, 0)
        let rightRun = max(rightMarkerX - highlightBounds.maxX, 0)
        let markerX = leftRun < rightRun ? leftMarkerX : rightMarkerX

        return CGPoint(
            x: markerX,
            y: min(
                max(highlightBounds.midY, pageBounds.minY + margin),
                pageBounds.maxY - margin
            )
        )
    }

    static func restoredMarkerCenter(
        placement: ReaderNotePlacement?,
        defaultMarkerCenter: CGPoint,
        pageBounds: CGRect
    ) -> CGPoint {
        // A saved placement is page-relative, but may be outside the crop box.
        // Do not silently pull it back into an arbitrary margin on reload.
        CGPoint(
            x: defaultMarkerCenter.x
                + (placement?.horizontalOffset ?? 0) * pageBounds.width,
            y: defaultMarkerCenter.y
                + (placement?.verticalOffset ?? 0) * pageBounds.height
        )
    }

    static func noteInkColor(for highlightColor: ReaderHighlightColor) -> NSColor {
        // These are the calmer, deeper companion tones used by the reflowable
        // reader. Keeping the opacity below one lets the note treatment soften
        // into the paper instead of competing with the highlight.
        let components: (red: CGFloat, green: CGFloat, blue: CGFloat) = switch highlightColor {
        case .lemon: (154 / 255, 133 / 255, 21 / 255)
        case .petal: (169 / 255, 79 / 255, 89 / 255)
        case .ember: (169 / 255, 93 / 255, 24 / 255)
        case .aqua: (39 / 255, 124 / 255, 130 / 255)
        case .moss: (47 / 255, 118 / 255, 89 / 255)
        }
        return NSColor(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 0.68
        )
    }

    init(
        annotationID: UUID,
        highlightBounds: CGRect,
        pageBounds: CGRect,
        defaultMarkerCenter: CGPoint,
        markerCenter: CGPoint,
        inkColor: NSColor
    ) {
        self.annotationID = annotationID
        self.highlightBounds = highlightBounds
        self.pageBounds = pageBounds
        self.defaultMarkerCenter = defaultMarkerCenter
        self.markerCenter = markerCenter
        self.inkColor = inkColor
        let drawingBounds = Self.drawingBounds(
            from: Self.leaderStart(
                highlightBounds: highlightBounds,
                markerCenter: markerCenter
            ),
            to: markerCenter
        )
        super.init(
            bounds: drawingBounds,
            forType: .ink,
            withProperties: nil
        )
        color = inkColor
        let markerBorder = PDFBorder()
        markerBorder.lineWidth = 1.25
        border = markerBorder
        redrawInkPaths()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func moveMarker(to point: CGPoint, within visiblePageBounds: CGRect) {
        markerCenter = CGPoint(
            x: min(max(point.x, visiblePageBounds.minX), visiblePageBounds.maxX),
            y: min(max(point.y, visiblePageBounds.minY), visiblePageBounds.maxY)
        )
        bounds = Self.drawingBounds(from: leaderStart, to: markerCenter)
        redrawInkPaths()
    }

    func beginMarkerMove() {
        fixedLeaderStart = leaderStart
    }

    func endMarkerMove() {
        fixedLeaderStart = nil
        bounds = Self.drawingBounds(from: leaderStart, to: markerCenter)
        redrawInkPaths()
    }

    private var leaderStart: CGPoint {
        if let fixedLeaderStart {
            return fixedLeaderStart
        }
        return Self.leaderStart(
            highlightBounds: highlightBounds,
            markerCenter: markerCenter
        )
    }

    private static func leaderStart(
        highlightBounds: CGRect,
        markerCenter: CGPoint
    ) -> CGPoint {
        var point = CGPoint(
            x: min(max(markerCenter.x, highlightBounds.minX), highlightBounds.maxX),
            y: min(max(markerCenter.y, highlightBounds.minY), highlightBounds.maxY)
        )
        if highlightBounds.contains(markerCenter) {
            let candidates = [
                (CGPoint(x: highlightBounds.minX, y: markerCenter.y), markerCenter.x - highlightBounds.minX),
                (CGPoint(x: highlightBounds.maxX, y: markerCenter.y), highlightBounds.maxX - markerCenter.x),
                (CGPoint(x: markerCenter.x, y: highlightBounds.minY), markerCenter.y - highlightBounds.minY),
                (CGPoint(x: markerCenter.x, y: highlightBounds.maxY), highlightBounds.maxY - markerCenter.y)
            ]
            point = candidates.min(by: { $0.1 < $1.1 })?.0 ?? point
        }
        return point
    }

    private static func drawingBounds(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x) - 16,
            y: min(start.y, end.y) - 16,
            width: abs(end.x - start.x) + 32,
            height: abs(end.y - start.y) + 32
        )
    }

    private func redrawInkPaths() {
        // PDFKit clips an ink annotation to its page crop box. The reader-owned
        // overlay draws the leader, ring, and dot instead, so a marker remains
        // complete when the reader lets it sit in the surrounding margin.
        paths?.forEach(remove)
    }
}

@MainActor
private final class PDFInlineRewriteState {
    let page: PDFPage
    let lineBounds: [NSRect]
    let selectionBounds: NSRect
    var loadingAnnotations: [PDFAnnotation] = []
    var loadingTicks: [PDFAnnotation] = []
    var resultBackdrop: PDFAnnotation?
    var resultAnnotation: PDFAnnotation?
    var resultText = ""
    var controls: PDFInlineRewriteControls?
    var loadingIndex = 0
    var isShowingOriginal = false

    init(page: PDFPage, lineBounds: [NSRect], selectionBounds: NSRect) {
        self.page = page
        self.lineBounds = lineBounds
        self.selectionBounds = selectionBounds
    }
}

@MainActor
private final class PDFInlineRewriteControls: NSView, NSTextFieldDelegate {
    var onAction: ((ReaderInlineRewriteAction) -> Void)?
    var onToggleOriginal: (() -> Void)?
    private var instructionField: NSTextField?
    private let content = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 10
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
        showActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var desiredSize: NSSize {
        layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        return NSSize(
            width: max(fitting.width + 20, 210),
            height: max(fitting.height + 10, 30)
        )
    }

    func showActions() {
        clearContent()
        let row = NSStackView(views: [
            button("original", action: #selector(toggleOriginal)),
            button("rewrite again…", action: #selector(beginInstruction)),
            button("dismiss", action: #selector(dismissRewrite))
        ])
        row.orientation = .horizontal
        row.spacing = 17
        content.addArrangedSubview(row)
    }

    func showFailure(_ message: String) {
        clearContent()
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        let label = NSTextField(labelWithString: message)
        style(label)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.48)
        row.addArrangedSubview(label)
        row.addArrangedSubview(button("retry", action: #selector(retryRewrite)))
        row.addArrangedSubview(button("dismiss", action: #selector(dismissRewrite)))
        content.addArrangedSubview(row)
    }

    private func showInstruction() {
        clearContent()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        let field = NSTextField()
        field.placeholderString = "how should this change?"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = italicFont(size: 12)
        field.textColor = .labelColor
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        instructionField = field
        row.addArrangedSubview(field)
        row.addArrangedSubview(button("rewrite", action: #selector(submitInstruction)))
        row.addArrangedSubview(button("cancel", action: #selector(cancelInstruction)))
        content.addArrangedSubview(row)
        let helper = NSTextField(labelWithString: "this rewrite only")
        helper.font = italicFont(size: 11)
        helper.textColor = NSColor.labelColor.withAlphaComponent(0.34)
        content.addArrangedSubview(helper)
        window?.makeFirstResponder(field)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitInstruction()
            return true
        }
        return false
    }

    private func clearContent() {
        instructionField = nil
        for view in content.arrangedSubviews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = italicFont(size: 12)
        button.contentTintColor = NSColor.labelColor.withAlphaComponent(0.48)
        button.setButtonType(.momentaryChange)
        return button
    }

    private func style(_ label: NSTextField) {
        label.font = italicFont(size: 12)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
    }

    private func italicFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .light)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    @objc private func toggleOriginal() {
        onToggleOriginal?()
    }

    @objc private func beginInstruction() {
        showInstruction()
    }

    @objc private func cancelInstruction() {
        showActions()
    }

    @objc private func submitInstruction() {
        let instruction = instructionField?.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard !instruction.isEmpty else { return }
        onAction?(.rewrite(instruction: instruction))
    }

    @objc private func retryRewrite() {
        onAction?(.retry)
    }

    @objc private func dismissRewrite() {
        onAction?(.dismiss)
    }
}

@MainActor
final class PDFKitReadingAdapter: NSObject, ReadingAdapter {
    let format = PublicationFormat.pdf
    let fingerprint: String
    let capabilities: ReadingCapabilities
    let sections: [ReaderSection]
    let pdfView: PDFView
    var onResourceIndexChanged: ((Int) -> Void)?
    var onScaleChanged: ((Double) -> Void)?
    var onAnnotationNoteRequested: ((ReaderAnnotationNoteRequest) -> Void)?
    var onAnnotationNotePlacementChanged: ((ReaderAnnotationNotePlacementRequest) -> Void)?
    private(set) var selectionViewportAnchor: ReaderViewportPoint?

    private let document: PDFDocument
    private var renderedAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var inlineRewrite: PDFInlineRewriteState?
    private var inlineRewriteAction: ReaderInlineRewriteAction?
    private var inlineRewriteTimer: Timer?
    private var searchSelectionsByResultIndex: [Int: PDFSelection] = [:]
    private var activeSearchSelectionIndex: Int?

    init(reference: PublicationReference) throws {
        guard let document = PDFDocument(url: reference.sourceURL) else {
            throw PublicationImportError.unreadablePDF
        }

        self.fingerprint = reference.fingerprint
        self.document = document
        let resolvedSections = Self.outlineSections(in: document)
        self.sections = resolvedSections
        var resolvedCapabilities: ReadingCapabilities = [
            .selectableText,
            .search,
            .highlights,
            .fixedPages
        ]
        if !resolvedSections.isEmpty {
            resolvedCapabilities.insert(.tableOfContents)
        }
        self.capabilities = resolvedCapabilities
        self.pdfView = ReaderPDFView()
        super.init()
        (pdfView as? ReaderPDFView)?.onAnnotationNoteRequested = { [weak self] request in
            self?.onAnnotationNoteRequested?(request)
        }
        (pdfView as? ReaderPDFView)?.onAnnotationNotePlacementChanged = { [weak self] request in
            self?.onAnnotationNotePlacementChanged?(request)
        }
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = false
        pdfView.pageBreakMargins = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: 0,
            right: 0
        )
        pdfView.pageShadowsEnabled = false
        pdfView.backgroundColor = .white
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageDidChange),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scaleDidChange),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var resourceCount: Int {
        document.pageCount
    }

    var currentResourceIndex: Int {
        guard let page = pdfView.currentPage else { return 0 }
        return max(document.index(for: page), 0)
    }

    func textChunks() throws -> [PublicationTextChunk] {
        (0..<document.pageCount).map { index in
            let page = document.page(at: index)
            return PublicationTextChunk(
                resourceID: resourceID(for: index),
                title: "Page \(index + 1)",
                text: page?.string ?? "",
                ordinal: index
            )
        }
    }

    static func resumeTextChunk(
        reference: PublicationReference,
        locator: ReaderLocator
    ) throws -> PublicationTextChunk? {
        guard let document = PDFDocument(url: reference.sourceURL) else {
            throw PublicationImportError.unreadablePDF
        }
        let index = pageIndex(for: locator, pageCount: document.pageCount)
        guard let page = document.page(at: index) else { return nil }
        return PublicationTextChunk(
            resourceID: "page-\(index)",
            title: "Page \(index + 1)",
            text: page.string ?? "",
            ordinal: index
        )
    }

    func navigate(to locator: ReaderLocator) {
        let index = pageIndex(for: locator)
        guard let page = document.page(at: index) else { return }
        pdfView.go(to: page)
        onResourceIndexChanged?(index)

        if let selection = selection(for: locator, on: page) {
            pdfView.go(to: selection)
        }
    }

    func navigate(toSearchResult locator: ReaderLocator) {
        navigate(to: locator)
    }

    func navigate(to section: ReaderSection) {
        guard
            section.resourceID.hasPrefix("page-"),
            let index = Int(section.resourceID.dropFirst("page-".count)),
            let page = document.page(at: index)
        else {
            return
        }
        pdfView.go(to: page)
        onResourceIndexChanged?(index)
    }

    func moveResource(by offset: Int) {
        let destination = min(
            max(currentResourceIndex + offset, 0),
            max(document.pageCount - 1, 0)
        )
        guard let page = document.page(at: destination) else { return }
        pdfView.go(to: page)
        onResourceIndexChanged?(destination)
    }

    func currentLocator() async -> ReaderLocator {
        let index = currentResourceIndex
        return ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: resourceID(for: index),
            position: index,
            progression: document.pageCount <= 1
                ? 0
                : Double(index) / Double(document.pageCount - 1)
        )
    }

    func captureSelection() async -> ReaderSelection? {
        guard
            let selection = pdfView.currentSelection,
            let selectedText = selection.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !selectedText.isEmpty,
            let page = selection.pages.first
        else {
            selectionViewportAnchor = nil
            return nil
        }

        let pageIndex = document.index(for: page)
        let bounds = selection.bounds(for: page)
        let viewBounds = pdfView.convert(bounds, from: page)
        selectionViewportAnchor = ReaderViewportPoint(
            x: viewBounds.midX,
            y: pdfView.isFlipped
                ? viewBounds.minY
                : pdfView.bounds.height - viewBounds.maxY
        )
        let pageText = page.string ?? ""
        let range = pageText.range(
            of: selectedText,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        let characterOffset = range.map {
            pageText.distance(from: pageText.startIndex, to: $0.lowerBound)
        } ?? 0
        let prefix = context(
            in: pageText,
            endingAt: characterOffset,
            maximumLength: 48
        )
        let suffix = context(
            in: pageText,
            startingAt: characterOffset + selectedText.count,
            maximumLength: 48
        )
        let locator = ReaderLocator(
            publicationFingerprint: fingerprint,
            resourceID: resourceID(for: pageIndex),
            position: characterOffset,
            progression: pageText.isEmpty
                ? 0
                : Double(characterOffset) / Double(pageText.count),
            textAnchor: TextAnchor(
                exact: selectedText,
                prefix: prefix,
                suffix: suffix
            ),
            rectangles: [
                ReaderRect(
                    x: bounds.origin.x,
                    y: bounds.origin.y,
                    width: bounds.width,
                    height: bounds.height
                )
            ]
        )
        return ReaderSelection(locator: locator, selectedText: selectedText)
    }

    func display(annotations: [ReaderAnnotation]) {
        for rendered in renderedAnnotations {
            rendered.page.removeAnnotation(rendered.annotation)
        }
        renderedAnnotations.removeAll()
        var renderedMarginNotes: [(page: PDFPage, annotation: ReaderPDFMarginNoteAnnotation)] = []

        for item in annotations where item.publicationFingerprint == fingerprint {
            let pageIndex = pageIndex(for: item.locator)
            guard let page = document.page(at: pageIndex) else { continue }

            var highlightBounds: CGRect?
            for rectangle in item.locator.rectangles {
                let bounds = NSRect(
                        x: rectangle.x,
                        y: rectangle.y,
                        width: rectangle.width,
                        height: rectangle.height
                    )
                highlightBounds = highlightBounds?.union(bounds) ?? bounds
                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .highlight,
                    withProperties: nil
                )
                annotation.color = NSColor(
                    red: CGFloat(item.highlightColor.red),
                    green: CGFloat(item.highlightColor.green),
                    blue: CGFloat(item.highlightColor.blue),
                    alpha: 0.38
                )
                page.addAnnotation(annotation)
                renderedAnnotations.append((page, annotation))
            }

            if
                item.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                let highlightBounds
            {
                let pageBounds = page.bounds(for: .cropBox)
                let defaultMarkerCenter = ReaderPDFMarginNoteAnnotation.defaultMarkerCenter(
                    highlightBounds: highlightBounds,
                    pageBounds: pageBounds
                )
                let markerCenter = ReaderPDFMarginNoteAnnotation.restoredMarkerCenter(
                    placement: item.notePlacement,
                    defaultMarkerCenter: defaultMarkerCenter,
                    pageBounds: pageBounds
                )
                let noteAnnotation = ReaderPDFMarginNoteAnnotation(
                    annotationID: item.id,
                    highlightBounds: highlightBounds,
                    pageBounds: pageBounds,
                    defaultMarkerCenter: defaultMarkerCenter,
                    markerCenter: markerCenter,
                    inkColor: ReaderPDFMarginNoteAnnotation.noteInkColor(
                        for: item.highlightColor
                    )
                )
                page.addAnnotation(noteAnnotation)
                renderedAnnotations.append((page, noteAnnotation))
                renderedMarginNotes.append((page, noteAnnotation))
            }
        }
        (pdfView as? ReaderPDFView)?.displayMarginNotes(renderedMarginNotes)
    }

    func display(searchResults: [ReaderSearchResult], activeIndex: Int?) {
        searchSelectionsByResultIndex = [:]
        let selections: [PDFSelection] = searchResults.enumerated().compactMap {
            index, result -> PDFSelection? in
            let pageIndex = pageIndex(for: result.locator)
            guard
                let page = document.page(at: pageIndex),
                let selection = selection(for: result.locator, on: page)
            else { return nil }
            selection.color = index == activeIndex
                ? NSColor(red: 1, green: 0.58, blue: 0.16, alpha: 0.72)
                : NSColor(red: 0.98, green: 0.88, blue: 0.22, alpha: 0.44)
            searchSelectionsByResultIndex[index] = selection
            return selection
        }
        activeSearchSelectionIndex = activeIndex
        pdfView.highlightedSelections = selections
    }

    func activateSearchResult(at index: Int?) {
        if let activeSearchSelectionIndex,
           let previous = searchSelectionsByResultIndex[activeSearchSelectionIndex] {
            previous.color = NSColor(
                red: 0.98,
                green: 0.88,
                blue: 0.22,
                alpha: 0.44
            )
        }
        if let index, let next = searchSelectionsByResultIndex[index] {
            next.color = NSColor(
                red: 1,
                green: 0.58,
                blue: 0.16,
                alpha: 0.72
            )
        }
        activeSearchSelectionIndex = index
        pdfView.highlightedSelections = searchSelectionsByResultIndex
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    func clearSelection() {
        selectionViewportAnchor = nil
        pdfView.clearSelection()
    }

    func beginInlineRewrite(_ selection: ReaderSelection) -> Bool {
        dismissInlineRewrite()
        guard
            let pdfSelection = pdfView.currentSelection,
            pdfSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                == selection.selectedText.trimmingCharacters(in: .whitespacesAndNewlines),
            pdfSelection.pages.count == 1,
            let page = pdfSelection.pages.first,
            page.rotation % 360 == 0
        else { return false }

        let selectedText = selection.selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !selectedText.contains("\n\n"),
            !selectedText.contains("\n•"),
            !selectedText.contains("\n▪"),
            !selectedText.contains("\n◦")
        else { return false }

        let lineBounds = pdfSelection.selectionsByLine()
            .map { $0.bounds(for: page) }
            .filter { $0.width > 12 && $0.height > 3 }
            .sorted { $0.maxY > $1.maxY }
        guard !lineBounds.isEmpty, lineBounds.count <= 14 else { return false }
        for (upper, lower) in zip(lineBounds, lineBounds.dropFirst()) {
            let gap = upper.minY - lower.maxY
            let allowedGap = max(upper.height, lower.height) * 0.8
            guard gap <= allowedGap else { return false }
        }
        let selectionBounds = lineBounds.reduce(NSRect.null) { partial, line in
            partial.union(line)
        }
        guard selectionBounds.width > 36, selectionBounds.height > 4 else {
            return false
        }

        pdfView.clearSelection()
        guard isPlainPaper(selectionBounds, on: page) else {
            pdfView.setCurrentSelection(pdfSelection, animate: false)
            return false
        }

        let state = PDFInlineRewriteState(
            page: page,
            lineBounds: lineBounds,
            selectionBounds: selectionBounds
        )
        inlineRewrite = state
        addLoadingAnnotations(to: state)
        startInlineRewriteAnimation()
        return true
    }

    func showInlineRewrite(_ text: String) {
        guard
            let state = inlineRewrite,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        stopInlineRewriteAnimation()
        removeLoadingAnnotations(from: state)
        state.controls?.removeFromSuperview()
        state.controls = nil
        if let existing = state.resultAnnotation {
            state.page.removeAnnotation(existing)
        }
        if let existing = state.resultBackdrop {
            state.page.removeAnnotation(existing)
        }

        let backdrop = PDFAnnotation(
            bounds: state.selectionBounds.insetBy(dx: -2.5, dy: -1.5),
            forType: .square,
            withProperties: nil
        )
        configureOverlayAnnotation(backdrop, color: .white)
        state.page.addAnnotation(backdrop)

        let annotation = PDFAnnotation(
            bounds: state.selectionBounds.insetBy(dx: -1, dy: 0),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = text.trimmingCharacters(in: .whitespacesAndNewlines)
        annotation.font = NSFont.systemFont(
            ofSize: min(
                max((state.lineBounds.map(\.height).max() ?? 13) * 0.72, 8),
                12.5
            ),
            weight: .regular
        )
        annotation.fontColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        annotation.interiorColor = .clear
        annotation.color = .clear
        annotation.alignment = .left
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        state.page.addAnnotation(annotation)
        state.resultBackdrop = backdrop
        state.resultAnnotation = annotation
        state.resultText = annotation.contents ?? text
        state.isShowingOriginal = false
        installControls(for: state)
        revealPDFLines(for: state)
    }

    func showInlineRewriteFailure(_ message: String) {
        guard let state = inlineRewrite else { return }
        stopInlineRewriteAnimation()
        removeLoadingAnnotations(from: state)
        let controls = controls(for: state)
        controls.showFailure(message)
        positionControls(for: state)
    }

    func restartInlineRewriteLoading() {
        guard let state = inlineRewrite else { return }
        state.controls?.removeFromSuperview()
        state.controls = nil
        addLoadingAnnotations(to: state)
        startInlineRewriteAnimation()
    }

    func captureInlineRewriteAction() -> ReaderInlineRewriteAction? {
        if let state = inlineRewrite {
            positionControls(for: state)
        }
        defer { inlineRewriteAction = nil }
        return inlineRewriteAction
    }

    func dismissInlineRewrite() {
        stopInlineRewriteAnimation()
        guard let state = inlineRewrite else { return }
        removeLoadingAnnotations(from: state)
        if let annotation = state.resultAnnotation {
            state.page.removeAnnotation(annotation)
        }
        if let backdrop = state.resultBackdrop {
            state.page.removeAnnotation(backdrop)
        }
        state.controls?.removeFromSuperview()
        inlineRewrite = nil
        inlineRewriteAction = nil
    }

    func setTextScale(_ scale: Double) {
        guard pdfView.document != nil else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(scale, 0.65), 2.5)
    }

    func setAppearance(_ preferences: QuietReadingPreferences) {
        let color: NSColor = switch preferences.theme {
        case .white: NSColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .cream: NSColor(red: 246 / 255, green: 242 / 255, blue: 232 / 255, alpha: 1)
        case .gray: NSColor(red: 230 / 255, green: 230 / 255, blue: 230 / 255, alpha: 1)
        case .dark: NSColor(red: 26 / 255, green: 26 / 255, blue: 28 / 255, alpha: 1)
        }
        pdfView.backgroundColor = color
    }

    private func addLoadingAnnotations(to state: PDFInlineRewriteState) {
        removeLoadingAnnotations(from: state)
        state.loadingIndex = 0
        for bounds in state.lineBounds {
            let wash = PDFAnnotation(
                bounds: bounds.insetBy(dx: -1, dy: 0),
                forType: .square,
                withProperties: nil
            )
            configureOverlayAnnotation(
                wash,
                color: NSColor(calibratedWhite: 0.18, alpha: 0.035)
            )
            state.page.addAnnotation(wash)
            state.loadingAnnotations.append(wash)

            let tick = PDFAnnotation(
                bounds: NSRect(
                    x: bounds.minX - 14,
                    y: bounds.midY - 0.6,
                    width: 8,
                    height: 1.2
                ),
                forType: .square,
                withProperties: nil
            )
            configureOverlayAnnotation(
                tick,
                color: NSColor(calibratedWhite: 0.12, alpha: 0.14)
            )
            state.page.addAnnotation(tick)
            state.loadingTicks.append(tick)
        }
        updateLoadingAnnotations(in: state)
    }

    private func removeLoadingAnnotations(from state: PDFInlineRewriteState) {
        for annotation in state.loadingAnnotations + state.loadingTicks {
            state.page.removeAnnotation(annotation)
        }
        state.loadingAnnotations.removeAll()
        state.loadingTicks.removeAll()
    }

    private func configureOverlayAnnotation(
        _ annotation: PDFAnnotation,
        color: NSColor
    ) {
        annotation.color = .clear
        annotation.interiorColor = color
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
    }

    private func startInlineRewriteAnimation() {
        stopInlineRewriteAnimation()
        guard let state = inlineRewrite else { return }
        updateLoadingAnnotations(in: state)
        inlineRewriteTimer = Timer.scheduledTimer(
            withTimeInterval: 0.36,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let state = self.inlineRewrite else { return }
                state.loadingIndex = min(
                    state.loadingIndex + 1,
                    max(state.loadingAnnotations.count - 1, 0)
                )
                self.updateLoadingAnnotations(in: state)
            }
        }
    }

    private func stopInlineRewriteAnimation() {
        inlineRewriteTimer?.invalidate()
        inlineRewriteTimer = nil
    }

    private func updateLoadingAnnotations(in state: PDFInlineRewriteState) {
        for index in state.loadingAnnotations.indices {
            let isComplete = index < state.loadingIndex
            let isActive = index == state.loadingIndex
            state.loadingAnnotations[index].interiorColor = NSColor(
                calibratedWhite: 0.15,
                alpha: isActive ? 0.09 : isComplete ? 0.025 : 0.04
            )
            state.loadingTicks[index].interiorColor = NSColor(
                calibratedWhite: 0.10,
                alpha: isActive ? 0.56 : isComplete ? 0.26 : 0.14
            )
        }
        pdfView.setNeedsDisplay(pdfView.bounds)
    }

    private func revealPDFLines(for state: PDFInlineRewriteState) {
        removeLoadingAnnotations(from: state)
        for bounds in state.lineBounds {
            let cover = PDFAnnotation(
                bounds: bounds.insetBy(dx: -1, dy: 0),
                forType: .square,
                withProperties: nil
            )
            configureOverlayAnnotation(cover, color: .white)
            state.page.addAnnotation(cover)
            state.loadingAnnotations.append(cover)

            let tick = PDFAnnotation(
                bounds: NSRect(
                    x: bounds.minX - 14,
                    y: bounds.midY - 0.6,
                    width: 8,
                    height: 1.2
                ),
                forType: .square,
                withProperties: nil
            )
            configureOverlayAnnotation(
                tick,
                color: NSColor(calibratedWhite: 0.10, alpha: 0.45)
            )
            state.page.addAnnotation(tick)
            state.loadingTicks.append(tick)
        }

        for index in state.loadingAnnotations.indices {
            Task { @MainActor [weak self, weak state] in
                try? await Task.sleep(for: .milliseconds(90 + index * 165))
                guard let self, let state, self.inlineRewrite === state else { return }
                guard
                    state.loadingAnnotations.indices.contains(index),
                    state.loadingTicks.indices.contains(index)
                else { return }
                state.page.removeAnnotation(state.loadingAnnotations[index])
                state.page.removeAnnotation(state.loadingTicks[index])
                self.pdfView.setNeedsDisplay(self.pdfView.bounds)
                if index == state.loadingAnnotations.count - 1 {
                    state.loadingAnnotations.removeAll()
                    state.loadingTicks.removeAll()
                }
            }
        }
    }

    private func installControls(for state: PDFInlineRewriteState) {
        let controls = controls(for: state)
        controls.showActions()
        positionControls(for: state)
    }

    private func controls(for state: PDFInlineRewriteState) -> PDFInlineRewriteControls {
        if let controls = state.controls { return controls }
        let controls = PDFInlineRewriteControls(frame: .zero)
        controls.onAction = { [weak self] action in
            self?.inlineRewriteAction = action
        }
        controls.onToggleOriginal = { [weak self, weak state] in
            guard let self, let state, let annotation = state.resultAnnotation else {
                return
            }
            if state.isShowingOriginal {
                if let backdrop = state.resultBackdrop {
                    state.page.addAnnotation(backdrop)
                }
                state.page.addAnnotation(annotation)
            } else {
                state.page.removeAnnotation(annotation)
                if let backdrop = state.resultBackdrop {
                    state.page.removeAnnotation(backdrop)
                }
            }
            state.isShowingOriginal.toggle()
            self.pdfView.setNeedsDisplay(self.pdfView.bounds)
        }
        state.controls = controls
        pdfView.addSubview(controls, positioned: .above, relativeTo: nil)
        return controls
    }

    private func positionControls(for state: PDFInlineRewriteState) {
        guard let controls = state.controls else { return }
        let selectionRect = pdfView.convert(state.selectionBounds, from: state.page)
        let desired = controls.desiredSize
        let x = min(
            max(selectionRect.midX - (desired.width / 2), 14),
            max(pdfView.bounds.width - desired.width - 14, 14)
        )
        let proposedY = pdfView.isFlipped
            ? selectionRect.minY - desired.height - 8
            : selectionRect.maxY + 8
        let y = min(
            max(proposedY, 12),
            max(pdfView.bounds.height - desired.height - 12, 12)
        )
        controls.frame = NSRect(origin: NSPoint(x: x, y: y), size: desired)
    }

    private func isPlainPaper(_ pageBounds: NSRect, on page: PDFPage) -> Bool {
        let expanded = pageBounds.insetBy(dx: -10, dy: -8)
        let viewBounds = pdfView.convert(expanded, from: page)
            .intersection(pdfView.bounds)
        guard
            viewBounds.width >= 24,
            viewBounds.height >= 12,
            let bitmap = pdfView.bitmapImageRepForCachingDisplay(in: viewBounds)
        else { return false }
        pdfView.cacheDisplay(in: viewBounds, to: bitmap)

        let strideX = max(bitmap.pixelsWide / 28, 1)
        let strideY = max(bitmap.pixelsHigh / 18, 1)
        var paperSamples = 0
        var samples = 0
        for x in Swift.stride(from: 0, to: bitmap.pixelsWide, by: strideX) {
            for y in Swift.stride(from: 0, to: bitmap.pixelsHigh, by: strideY) {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let spread = max(red, green, blue) - min(red, green, blue)
                if (red + green + blue) / 3 > 0.88, spread < 0.10 {
                    paperSamples += 1
                }
                samples += 1
            }
        }
        return samples > 0 && Double(paperSamples) / Double(samples) >= 0.74
    }

    private func resourceID(for pageIndex: Int) -> String {
        "page-\(pageIndex)"
    }

    private func selection(
        for locator: ReaderLocator,
        on page: PDFPage
    ) -> PDFSelection? {
        guard
            let pageText = page.string,
            let start = pageText.index(
                pageText.startIndex,
                offsetBy: min(max(locator.position, 0), pageText.count),
                limitedBy: pageText.endIndex
            )
        else { return nil }

        let exact = locator.textAnchor?.exact ?? ""
        let location = pageText[..<start].utf16.count
        let length = max(exact.utf16.count, 1)
        return page.selection(for: NSRange(location: location, length: length))
    }

    @objc
    private func pageDidChange() {
        (pdfView as? ReaderPDFView)?.refreshMarginNotes()
        onResourceIndexChanged?(currentResourceIndex)
    }

    @objc
    private func scaleDidChange() {
        (pdfView as? ReaderPDFView)?.refreshMarginNotes()
        onScaleChanged?(pdfView.scaleFactor)
    }

    private static func outlineSections(
        in document: PDFDocument
    ) -> [ReaderSection] {
        guard let root = document.outlineRoot else { return [] }
        var result: [ReaderSection] = []

        func appendChildren(
            of outline: PDFOutline,
            depth: Int,
            path: String
        ) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let childPath = path.isEmpty ? "\(index)" : "\(path)-\(index)"
                if
                    let page = child.destination?.page,
                    let title = child.label?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    !title.isEmpty
                {
                    let pageIndex = document.index(for: page)
                    result.append(
                        ReaderSection(
                            id: "pdf-outline-\(childPath)",
                            title: title,
                            resourceID: "page-\(pageIndex)",
                            depth: depth
                        )
                    )
                }
                appendChildren(
                    of: child,
                    depth: depth + 1,
                    path: childPath
                )
            }
        }

        appendChildren(of: root, depth: 0, path: "")
        return result
    }

    private func pageIndex(for locator: ReaderLocator) -> Int {
        Self.pageIndex(for: locator, pageCount: document.pageCount)
    }

    private static func pageIndex(
        for locator: ReaderLocator,
        pageCount: Int
    ) -> Int {
        if
            locator.resourceID.hasPrefix("page-"),
            let index = Int(locator.resourceID.dropFirst("page-".count))
        {
            return min(max(index, 0), max(pageCount - 1, 0))
        }
        return min(max(locator.position, 0), max(pageCount - 1, 0))
    }

    private func context(
        in text: String,
        endingAt characterOffset: Int,
        maximumLength: Int
    ) -> String {
        guard let end = text.index(
            text.startIndex,
            offsetBy: characterOffset,
            limitedBy: text.endIndex
        ) else {
            return ""
        }
        let start = text.index(
            end,
            offsetBy: -maximumLength,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        return String(text[start..<end])
    }

    private func context(
        in text: String,
        startingAt characterOffset: Int,
        maximumLength: Int
    ) -> String {
        guard let start = text.index(
            text.startIndex,
            offsetBy: characterOffset,
            limitedBy: text.endIndex
        ) else {
            return ""
        }
        let end = text.index(
            start,
            offsetBy: maximumLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        return String(text[start..<end])
    }
}

struct PDFKitSurfaceView: NSViewRepresentable {
    let adapter: PDFKitReadingAdapter

    func makeNSView(context: Context) -> PDFView {
        adapter.pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}

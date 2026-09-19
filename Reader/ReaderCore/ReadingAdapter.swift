import Foundation

enum ReaderInlineRewriteAction: Equatable, Sendable {
    case dismiss
    case retry
    case rewrite(instruction: String)
}

@MainActor
protocol ReadingAdapter: AnyObject {
    var format: PublicationFormat { get }
    var fingerprint: String { get }
    var capabilities: ReadingCapabilities { get }
    var resourceCount: Int { get }
    var currentResourceIndex: Int { get }
    var selectionViewportAnchor: ReaderViewportPoint? { get }
    var sections: [ReaderSection] { get }
    var onResourceIndexChanged: ((Int) -> Void)? { get set }
    var onScaleChanged: ((Double) -> Void)? { get set }
    var onAnnotationNoteRequested: ((ReaderAnnotationNoteRequest) -> Void)? { get set }
    var onAnnotationNotePlacementChanged: ((ReaderAnnotationNotePlacementRequest) -> Void)? {
        get set
    }

    func textChunks() throws -> [PublicationTextChunk]
    func navigate(to locator: ReaderLocator)
    func navigate(toSearchResult locator: ReaderLocator)
    func navigate(to section: ReaderSection)
    func moveResource(by offset: Int)
    func currentLocator() async -> ReaderLocator
    func captureSelection() async -> ReaderSelection?
    func clearSelection()
    func display(annotations: [ReaderAnnotation])
    func display(searchResults: [ReaderSearchResult], activeIndex: Int?)
    func activateSearchResult(at index: Int?)
    func setTextScale(_ scale: Double)
}

enum ReadingBackend {
    case pdf(PDFKitReadingAdapter)
    case web(WebKitReadingAdapter)

    var adapter: any ReadingAdapter {
        switch self {
        case .pdf(let adapter):
            adapter
        case .web(let adapter):
            adapter
        }
    }
}

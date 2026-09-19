import Foundation
import Observation

@MainActor
@Observable
final class BrowserSession {
    static let homeURL = URL(string: "https://www.google.com/")!

    var addressText: String
    private(set) var currentURL: URL?
    private(set) var title: String
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    var navigationRequest: BrowserNavigationRequest?
    @ObservationIgnored var onStateChanged: (() -> Void)?
    @ObservationIgnored private var retainedPlatformSurface: AnyObject?
    @ObservationIgnored private var lastHandledNavigationRequestID: UUID?

    init(homeURL: URL = BrowserSession.homeURL) {
        addressText = homeURL.absoluteString
        currentURL = homeURL
        title = homeURL.host == "www.google.com" ? "Google" : homeURL.host ?? "New tab"
        navigationRequest = BrowserNavigationRequest(kind: .load(homeURL))
    }

    init(snapshot: BrowserSessionSnapshot) {
        addressText = snapshot.url.absoluteString
        currentURL = snapshot.url
        title = snapshot.title
        navigationRequest = BrowserNavigationRequest(kind: .load(snapshot.url))
    }

    var snapshot: BrowserSessionSnapshot {
        BrowserSessionSnapshot(
            url: currentURL ?? URL(string: addressText) ?? Self.homeURL,
            title: title
        )
    }

    func navigateFromAddressBar() {
        let input = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let url: URL?
        if input.contains(" ") || !input.contains(".") {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: input)]
            url = components?.url
        } else if input.hasPrefix("http://") || input.hasPrefix("https://") {
            url = URL(string: input)
        } else {
            url = URL(string: "https://\(input)")
        }

        guard let url else { return }
        currentURL = url
        addressText = url.absoluteString
        navigationRequest = BrowserNavigationRequest(kind: .load(url))
        onStateChanged?()
    }

    func goBack() {
        navigationRequest = BrowserNavigationRequest(kind: .back)
    }

    func goForward() {
        navigationRequest = BrowserNavigationRequest(kind: .forward)
    }

    func reloadOrStop() {
        navigationRequest = BrowserNavigationRequest(kind: isLoading ? .stop : .reload)
    }

    func platformSurface<Surface: AnyObject>(make: () -> Surface) -> Surface {
        if let existing = retainedPlatformSurface as? Surface {
            return existing
        }

        let surface = make()
        retainedPlatformSurface = surface
        return surface
    }

    func takeNavigationRequest() -> BrowserNavigationRequest? {
        guard
            let request = navigationRequest,
            request.id != lastHandledNavigationRequestID
        else { return nil }

        lastHandledNavigationRequestID = request.id
        return request
    }

    func didUpdate(
        url: URL?,
        title: String?,
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool
    ) {
        currentURL = url
        if let url { addressText = url.absoluteString }
        let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = cleanedTitle?.isEmpty == false
            ? cleanedTitle ?? "New tab"
            : url?.host ?? "New tab"
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        onStateChanged?()
    }
}

struct BrowserSessionSnapshot: Codable, Equatable, Sendable {
    let url: URL
    let title: String
}

struct BrowserNavigationRequest: Equatable, Identifiable {
    enum Kind: Equatable {
        case load(URL)
        case back
        case forward
        case reload
        case stop
    }

    let id = UUID()
    let kind: Kind
}

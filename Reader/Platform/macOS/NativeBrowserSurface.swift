#if os(macOS)
import AppKit
import SwiftUI
import WebKit

struct NativeBrowserSurface: NSViewRepresentable {
    @Bindable var session: BrowserSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView: WKWebView = session.platformSurface {
            Self.makeWebView()
        }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.observe(webView)
        return webView
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.applicationNameForUserAgent = Self.safariCompatibilityProduct
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    private static var safariCompatibilityProduct: String {
        let safariVersion = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let fallbackVersion = ProcessInfo.processInfo.operatingSystemVersion
        let version = safariVersion
            ?? "\(fallbackVersion.majorVersion).\(fallbackVersion.minorVersion)"

        // macOS WKWebView intentionally omits Safari's Version/Safari product
        // tokens from its default UA. Google treats that UA as an old generic
        // WebKit client, so append the installed Safari product while leaving
        // WebKit's platform-generated UA intact.
        return "Version/\(version) Safari/605.1.15"
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let request = session.takeNavigationRequest() else { return }

        switch request.kind {
        case .load(let url):
            webView.load(URLRequest(url: url))
        case .back:
            webView.goBack()
        case .forward:
            webView.goForward()
        case .reload:
            webView.reload()
        case .stop:
            webView.stopLoading()
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let session: BrowserSession
        private var observations: [NSKeyValueObservation] = []

        init(session: BrowserSession) {
            self.session = session
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.url, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                    self?.schedulePublish(webView)
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                    self?.schedulePublish(webView)
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                    self?.schedulePublish(webView)
                },
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                    self?.schedulePublish(webView)
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                    self?.schedulePublish(webView)
                },
            ]
        }

        nonisolated private func schedulePublish(_ webView: WKWebView?) {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                session.didUpdate(
                    url: webView.url,
                    title: webView.title,
                    canGoBack: webView.canGoBack,
                    canGoForward: webView.canGoForward,
                    isLoading: webView.isLoading
                )
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
                webView.load(URLRequest(url: requestURL))
            }
            return nil
        }
    }
}
#endif

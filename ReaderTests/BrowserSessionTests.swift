import XCTest
@testable import Reader

@MainActor
final class BrowserSessionTests: XCTestCase {
    func testBrowserStartsLoadingDesktopGoogle() throws {
        let session = BrowserSession()

        XCTAssertEqual(session.currentURL, BrowserSession.homeURL)
        XCTAssertEqual(session.addressText, "https://www.google.com/")
        XCTAssertEqual(session.title, "Google")
        XCTAssertEqual(
            try XCTUnwrap(session.navigationRequest).kind,
            .load(BrowserSession.homeURL)
        )
    }

    func testBareDomainBecomesHTTPSURL() throws {
        let session = BrowserSession()
        session.addressText = "example.com"

        session.navigateFromAddressBar()

        XCTAssertEqual(session.currentURL, URL(string: "https://example.com"))
        let request = try XCTUnwrap(session.navigationRequest)
        XCTAssertEqual(request.kind, .load(try XCTUnwrap(session.currentURL)))
    }

    func testWordsBecomeGoogleSearch() throws {
        let session = BrowserSession()
        session.addressText = "Virginia Woolf portrait"

        session.navigateFromAddressBar()

        let url = try XCTUnwrap(session.currentURL)
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "q", value: "Virginia Woolf portrait")]
        )
    }

    func testBrowserStateUpdatesFromNativeSurface() {
        let session = BrowserSession()
        let url = URL(string: "https://example.com/article")

        session.didUpdate(
            url: url,
            title: "An Article",
            canGoBack: true,
            canGoForward: false,
            isLoading: true
        )

        XCTAssertEqual(session.addressText, url?.absoluteString)
        XCTAssertEqual(session.title, "An Article")
        XCTAssertTrue(session.canGoBack)
        XCTAssertFalse(session.canGoForward)
        XCTAssertTrue(session.isLoading)
    }

    func testBrowserRetainsItsNativeSurfaceAcrossViewRecreation() {
        let session = BrowserSession()
        let first: NSObject = session.platformSurface { NSObject() }
        let second: NSObject = session.platformSurface { NSObject() }

        XCTAssertTrue(first === second)
    }

    func testNavigationRequestIsHandledOnlyOnceAcrossViewRecreation() throws {
        let session = BrowserSession()

        XCTAssertEqual(
            try XCTUnwrap(session.takeNavigationRequest()).kind,
            .load(BrowserSession.homeURL)
        )
        XCTAssertNil(session.takeNavigationRequest())

        session.addressText = "example.com"
        session.navigateFromAddressBar()

        XCTAssertEqual(
            try XCTUnwrap(session.takeNavigationRequest()).kind,
            .load(URL(string: "https://example.com")!)
        )
        XCTAssertNil(session.takeNavigationRequest())
    }
}

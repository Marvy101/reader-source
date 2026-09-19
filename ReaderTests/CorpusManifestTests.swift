import CryptoKit
import Foundation
import XCTest

enum ReaderTestCorpus {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var stagedRoot: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appending(path: "Reader/TestCorpus", directoryHint: .isDirectory)
    }

    static var rootDirectory: URL {
        let stagedManifest = stagedRoot.appending(path: "manifest.json")
        if FileManager.default.fileExists(atPath: stagedManifest.path) {
            return stagedRoot
        }
        return repositoryRoot.appending(
            path: "TestCorpus",
            directoryHint: .isDirectory
        )
    }

    static var downloadDirectory: URL {
        rootDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    static var manifestURL: URL {
        rootDirectory.appending(path: "manifest.json")
    }
}

final class CorpusManifestTests: XCTestCase {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let id: String
        let fileName: String
        let format: String
        let renderProfile: String
        let sizeClass: String
        let sizeBytes: Int
        let sha256: String
        let coverExpectation: String
        let sourceURL: URL
        let sourcePage: URL
        let rightsURL: URL
        let publicDomainUS: Bool
    }

    func testManifestHasUniqueReproduciblePublicDomainFixtures() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.fixtures.count, 10)
        XCTAssertEqual(Set(manifest.fixtures.map(\.id)).count, manifest.fixtures.count)
        XCTAssertEqual(Set(manifest.fixtures.map(\.fileName)).count, manifest.fixtures.count)

        for fixture in manifest.fixtures {
            XCTAssertEqual(fixture.sourceURL.scheme, "https", fixture.id)
            XCTAssertEqual(fixture.sourcePage.scheme, "https", fixture.id)
            XCTAssertEqual(fixture.rightsURL.scheme, "https", fixture.id)
            XCTAssertTrue(fixture.publicDomainUS, fixture.id)
            XCTAssertGreaterThan(fixture.sizeBytes, 0, fixture.id)
            XCTAssertEqual(fixture.sha256.count, 64, fixture.id)
            XCTAssertTrue(fixture.sha256.allSatisfy(\.isHexDigit), fixture.id)
            XCTAssertFalse(fixture.fileName.contains("/"), fixture.id)
        }
    }

    func testManifestCoversFormatsSizesAndCoverPaths() throws {
        let fixtures = try loadManifest().fixtures

        XCTAssertEqual(Set(fixtures.map(\.format)), Set(["epub", "mobi", "pdf", "txt"]))
        XCTAssertEqual(
            Set(fixtures.map(\.sizeClass)),
            Set(["tiny", "small", "medium", "large", "huge"])
        )
        XCTAssertEqual(
            Set(fixtures.map(\.coverExpectation)),
            Set(["embedded", "firstPage", "none"])
        )

        let profiles = Set(fixtures.map(\.renderProfile))
        XCTAssertTrue(profiles.contains("reflowable"))
        XCTAssertTrue(profiles.contains("legacyReflowable"))
        XCTAssertTrue(profiles.contains("digitalPDF"))
        XCTAssertTrue(profiles.contains("imageOnlyPDF"))
        XCTAssertTrue(profiles.contains("ocrScanPDF"))
        XCTAssertTrue(profiles.contains("plainText"))
    }

    func testDownloadedCorpusMatchesManifestWhenPresent() throws {
        let downloadDirectory = ReaderTestCorpus.downloadDirectory
        let contents = try? FileManager.default.contentsOfDirectory(
            at: downloadDirectory,
            includingPropertiesForKeys: nil
        )

        try XCTSkipIf(contents?.isEmpty != false, "Run scripts/download_test_corpus.sh first.")

        for fixture in try loadManifest().fixtures {
            let fileURL = downloadDirectory.appending(path: fixture.fileName)
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()

            XCTAssertEqual(data.count, fixture.sizeBytes, fixture.id)
            XCTAssertEqual(digest, fixture.sha256, fixture.id)
        }
    }

    private func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: ReaderTestCorpus.manifestURL)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }
}

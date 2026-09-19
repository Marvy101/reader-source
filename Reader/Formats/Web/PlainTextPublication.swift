import Foundation

struct PlainTextPublication: Sendable {
    let title: String
    let fingerprint: String
    let rootDirectory: URL
    let documentURL: URL
    let text: String

    static func load(from sourceURL: URL) throws -> PlainTextPublication {
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        guard let text = decode(url: sourceURL) else {
            throw PublicationImportError.unreadableText
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appending(path: "Reader", directoryHint: .isDirectory)
            .appending(path: "TextCache", directoryHint: .isDirectory)
            .appending(path: fingerprint, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let documentURL = directory.appending(path: "content.html")

        if !FileManager.default.fileExists(atPath: documentURL.path) {
            let paragraphs = text
                .components(separatedBy: "\n\n")
                .map { paragraph in
                    paragraph
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .escapedForHTML
                        .replacingOccurrences(of: "\n", with: "<br>")
                }
                .filter { !$0.isEmpty }
                .map { "<p>\($0)</p>" }
                .joined(separator: "\n")
            let html = """
                <!doctype html>
                <html lang="en">
                <head>
                  <meta charset="utf-8">
                  <title>\(sourceURL.deletingPathExtension().lastPathComponent.escapedForHTML)</title>
                </head>
                <body>
                  <article>
                    \(paragraphs)
                  </article>
                </body>
                </html>
                """
            try html.write(
                to: documentURL,
                atomically: true,
                encoding: .utf8
            )
        }

        return PlainTextPublication(
            title: sourceURL.deletingPathExtension().lastPathComponent,
            fingerprint: fingerprint,
            rootDirectory: directory,
            documentURL: documentURL,
            text: text
        )
    }

    static func decode(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }
}

private extension String {
    var escapedForHTML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum PublicationImportError: LocalizedError {
    case unsupportedFormat
    case unreadablePDF
    case unreadableText

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Reader currently imports PDF, EPUB, and TXT files."
        case .unreadablePDF:
            "PDFKit could not open this PDF."
        case .unreadableText:
            "Reader could not decode this text file."
        }
    }
}

@MainActor
enum PublicationImportService {
    static func importBook(
        from selectedURL: URL,
        libraryRoot: URL? = nil
    ) throws -> Book {
        let hasSecurityAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let format = try format(for: selectedURL)
        let fingerprint = try FileFingerprint.sha256(of: selectedURL)
        let importedURL = try copyIntoLibrary(
            selectedURL,
            fingerprint: fingerprint,
            libraryRoot: libraryRoot
        )

        switch format {
        case .pdf:
            return try importPDF(
                at: importedURL,
                fingerprint: fingerprint
            )
        case .epub:
            return try importEPUB(at: importedURL)
        case .plainText:
            return try importPlainText(
                at: importedURL,
                fingerprint: fingerprint
            )
        }
    }

    private static func format(for url: URL) throws -> PublicationFormat {
        switch url.pathExtension.lowercased() {
        case "pdf":
            .pdf
        case "epub":
            .epub
        case "txt", "text":
            .plainText
        default:
            throw PublicationImportError.unsupportedFormat
        }
    }

    private static func copyIntoLibrary(
        _ sourceURL: URL,
        fingerprint: String,
        libraryRoot: URL?
    ) throws -> URL {
        let resolvedRoot = try libraryRoot
            ?? ReaderLibraryPaths.live().rootURL
        let directory = resolvedRoot
            .appending(path: "Imports", directoryHint: .isDirectory)
            .appending(path: fingerprint, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let destination = directory.appending(path: sourceURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
        return destination
    }

    private static func importPDF(
        at url: URL,
        fingerprint: String
    ) throws -> Book {
        guard let document = PDFDocument(url: url) else {
            throw PublicationImportError.unreadablePDF
        }

        let title = document.documentAttributes?[
            PDFDocumentAttribute.titleAttribute
        ] as? String
        let author = document.documentAttributes?[
            PDFDocumentAttribute.authorAttribute
        ] as? String
        let coverURL = try makePDFCover(
            document: document,
            beside: url
        )
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? url.deletingPathExtension().lastPathComponent

        return Book(
            title: resolvedTitle,
            author: author?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? "Unknown author",
            progress: 0,
            coverStyle: coverStyle(for: fingerprint),
            formatLabel: PublicationFormat.pdf.displayName,
            readingLength: .pages(document.pageCount),
            sample: ReadingSample(
                chapter: "\(document.pageCount) pages",
                section: "Fixed-layout PDF",
                paragraphs: []
            ),
            publication: PublicationReference(
                sourceURL: url,
                format: .pdf,
                fingerprint: fingerprint,
                coverURL: coverURL
            )
        )
    }

    private static func importEPUB(at url: URL) throws -> Book {
        let publication = try EPUBPublicationLoader.load(from: url)
        let estimatedPageCount = ReflowablePageEstimator.estimate(
            resources: publication.spine
        )
        let coverURL = try copyEPUBCover(
            publication.coverURL,
            beside: url
        )

        return Book(
            title: publication.title,
            author: publication.author,
            progress: 0,
            coverStyle: coverStyle(for: publication.fingerprint),
            formatLabel: PublicationFormat.epub.displayName,
            readingLength: .estimatedPages(estimatedPageCount),
            sample: ReadingSample(
                chapter: "≈ \(estimatedPageCount) pages",
                section: "Reflowable EPUB",
                paragraphs: []
            ),
            publication: PublicationReference(
                sourceURL: url,
                format: .epub,
                fingerprint: publication.fingerprint,
                coverURL: coverURL
            )
        )
    }

    private static func copyEPUBCover(
        _ extractedCoverURL: URL?,
        beside sourceURL: URL
    ) throws -> URL? {
        guard let extractedCoverURL else { return nil }

        let fileExtension = extractedCoverURL.pathExtension.nilIfEmpty ?? "img"
        let managedCoverURL = sourceURL
            .deletingLastPathComponent()
            .appending(path: "cover.\(fileExtension)")

        if !FileManager.default.fileExists(atPath: managedCoverURL.path) {
            try FileManager.default.copyItem(
                at: extractedCoverURL,
                to: managedCoverURL
            )
        }
        return managedCoverURL
    }

    private static func importPlainText(
        at url: URL,
        fingerprint: String
    ) throws -> Book {
        guard let text = PlainTextPublication.decode(url: url) else {
            throw PublicationImportError.unreadableText
        }

        let estimatedPages = max(Int(ceil(Double(text.count) / 1_800)), 1)

        return Book(
            title: url.deletingPathExtension().lastPathComponent,
            author: "Unknown author",
            progress: 0,
            coverStyle: coverStyle(for: fingerprint),
            formatLabel: PublicationFormat.plainText.displayName,
            readingLength: .estimatedPages(estimatedPages),
            sample: ReadingSample(
                chapter: "Plain text",
                section: "Reflowable text",
                paragraphs: []
            ),
            publication: PublicationReference(
                sourceURL: url,
                format: .plainText,
                fingerprint: fingerprint,
                coverURL: nil
            )
        )
    }

    private static func makePDFCover(
        document: PDFDocument,
        beside sourceURL: URL
    ) throws -> URL? {
        guard
            let page = document.page(at: 0),
            let tiff = page
                .thumbnail(
                    of: NSSize(width: 720, height: 1_080),
                    for: .cropBox
                )
                .tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        let coverURL = sourceURL
            .deletingLastPathComponent()
            .appending(path: "cover.png")
        try png.write(to: coverURL, options: .atomic)
        return coverURL
    }

    private static func coverStyle(for fingerprint: String) -> BookCoverStyle {
        let styles: [BookCoverStyle] = [
            .forest,
            .night,
            .parchment,
            .clay,
            .sea
        ]
        let value = Int(fingerprint.prefix(2), radix: 16) ?? 0
        return styles[value % styles.count]
    }
}

extension UTType {
    static var readerEPUB: UTType {
        UTType(filenameExtension: "epub")
            ?? UTType(
                importedAs: "org.idpf.epub-container",
                conformingTo: .zip
            )
    }
}

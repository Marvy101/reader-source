import Foundation
import ZIPFoundation

struct EPUBResource: Hashable, Sendable {
    let id: String
    let href: String
    let mediaType: String
    let properties: Set<String>
    let fileURL: URL
}

struct EPUBNavigationItem: Hashable, Sendable {
    let title: String
    let resourceID: String
    let fragment: String?
    let depth: Int
}

struct EPUBPublication: Sendable {
    let title: String
    let author: String
    let fingerprint: String
    let rootDirectory: URL
    let packageURL: URL
    let spine: [EPUBResource]
    let tableOfContents: [EPUBNavigationItem]
    let coverURL: URL?
}

enum EPUBLoadingError: LocalizedError {
    case archiveCannotOpen
    case archiveTooLarge
    case unsafeArchivePath(String)
    case symbolicLinkNotAllowed(String)
    case missingContainer
    case missingPackagePath
    case missingPackage
    case emptySpine

    var errorDescription: String? {
        switch self {
        case .archiveCannotOpen:
            "This EPUB archive could not be opened."
        case .archiveTooLarge:
            "This EPUB expands beyond the Reader safety limit."
        case .unsafeArchivePath(let path):
            "The EPUB contains an unsafe path: \(path)"
        case .symbolicLinkNotAllowed(let path):
            "The EPUB contains a symbolic link, which Reader does not allow: \(path)"
        case .missingContainer:
            "The EPUB is missing META-INF/container.xml."
        case .missingPackagePath:
            "The EPUB container does not identify its package document."
        case .missingPackage:
            "The EPUB package document could not be read."
        case .emptySpine:
            "The EPUB does not contain a readable spine."
        }
    }
}

enum EPUBPublicationLoader {
    private static let maximumEntries = 20_000
    private static let maximumExpandedBytes: UInt64 = 750 * 1_024 * 1_024

    static func load(from sourceURL: URL) throws -> EPUBPublication {
        let fingerprint = try FileFingerprint.sha256(of: sourceURL)
        let extractionRoot = try extractionDirectory(for: fingerprint)
        let completionMarker = extractionRoot.appending(path: ".reader-extracted")

        if !FileManager.default.fileExists(atPath: completionMarker.path) {
            try extractArchive(from: sourceURL, to: extractionRoot)
            FileManager.default.createFile(
                atPath: completionMarker.path,
                contents: Data()
            )
        }

        let containerURL = extractionRoot.appending(path: "META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL) else {
            throw EPUBLoadingError.missingContainer
        }

        let containerParser = EPUBContainerParser()
        guard
            let packagePath = containerParser.packagePath(in: containerData),
            !packagePath.isEmpty
        else {
            throw EPUBLoadingError.missingPackagePath
        }

        let packageURL = try safeURL(
            forRelativePath: packagePath,
            inside: extractionRoot
        )
        guard let packageData = try? Data(contentsOf: packageURL) else {
            throw EPUBLoadingError.missingPackage
        }

        let package = EPUBPackageParser().parse(packageData)
        let packageDirectory = packageURL.deletingLastPathComponent()
        let resourcesByID = try Dictionary(
            uniqueKeysWithValues: package.manifest.map { item in
                let decodedHref = item.href.removingPercentEncoding ?? item.href
                let fileURL = try safeURL(
                    forRelativePath: decodedHref,
                    inside: packageDirectory
                )
                return (
                    item.id,
                    EPUBResource(
                        id: item.id,
                        href: item.href,
                        mediaType: item.mediaType,
                        properties: item.properties,
                        fileURL: fileURL
                    )
                )
            }
        )
        let spine = package.spine.compactMap { resourcesByID[$0] }

        guard !spine.isEmpty else {
            throw EPUBLoadingError.emptySpine
        }

        let coverID = package.coverID
            ?? package.manifest.first(where: {
                $0.properties.contains("cover-image")
            })?.id
        let tableOfContents = try loadTableOfContents(
            package: package,
            packageDirectory: packageDirectory,
            resourcesByID: resourcesByID,
            spine: spine
        )

        return EPUBPublication(
            title: package.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? sourceURL.deletingPathExtension().lastPathComponent,
            author: package.author?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? "Unknown author",
            fingerprint: fingerprint,
            rootDirectory: extractionRoot,
            packageURL: packageURL,
            spine: spine,
            tableOfContents: tableOfContents,
            coverURL: coverID.flatMap { resourcesByID[$0]?.fileURL }
        )
    }

    private static func loadTableOfContents(
        package: EPUBPackage,
        packageDirectory: URL,
        resourcesByID: [String: EPUBResource],
        spine: [EPUBResource]
    ) throws -> [EPUBNavigationItem] {
        let navigationItem = package.manifest.first {
            $0.properties.contains("nav")
        }
        let legacyNCXItem = package.manifest.first {
            $0.mediaType == "application/x-dtbncx+xml"
        }
        let sourceItem = navigationItem ?? legacyNCXItem

        guard
            let sourceItem,
            let sourceResource = resourcesByID[sourceItem.id],
            let data = try? Data(contentsOf: sourceResource.fileURL)
        else {
            return []
        }

        let rawItems = navigationItem != nil
            ? EPUBNavigationParser().parse(data)
            : EPUBNCXParser().parse(data)
        let spineByPath = Dictionary(
            uniqueKeysWithValues: spine.map {
                ($0.fileURL.standardizedFileURL.path, $0)
            }
        )

        return rawItems.enumerated().compactMap { index, item in
            guard
                let destination = resolveNavigationDestination(
                    item.href,
                    relativeTo: sourceResource.fileURL,
                    packageDirectory: packageDirectory
                ),
                let resource = spineByPath[
                    destination.fileURL.standardizedFileURL.path
                ]
            else {
                return nil
            }

            let title = item.title.normalizedReaderWhitespace
            guard !title.isEmpty else { return nil }

            return EPUBNavigationItem(
                title: title,
                resourceID: resource.id,
                fragment: destination.fragment,
                depth: item.depth
            )
        }
    }

    private static func resolveNavigationDestination(
        _ href: String,
        relativeTo navigationURL: URL,
        packageDirectory: URL
    ) -> (fileURL: URL, fragment: String?)? {
        guard
            let resolved = URL(
                string: href,
                relativeTo: navigationURL
                    .deletingLastPathComponent()
                    .appending(path: "", directoryHint: .isDirectory)
            )?.absoluteURL
        else {
            return nil
        }

        var components = URLComponents(
            url: resolved,
            resolvingAgainstBaseURL: false
        )
        let fragment = components?.fragment?.removingPercentEncoding
        components?.fragment = nil
        components?.query = nil
        guard let fileURL = components?.url, fileURL.isFileURL else {
            return nil
        }

        let packagePath = packageDirectory.standardizedFileURL.path + "/"
        guard fileURL.standardizedFileURL.path.hasPrefix(packagePath) else {
            return nil
        }
        return (fileURL, fragment?.nilIfEmpty)
    }

    private static func extractionDirectory(for fingerprint: String) throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appending(path: "Reader", directoryHint: .isDirectory)
            .appending(path: "EPUBCache", directoryHint: .isDirectory)
            .appending(path: fingerprint, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func extractArchive(from sourceURL: URL, to root: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: sourceURL, accessMode: .read)
        } catch {
            throw EPUBLoadingError.archiveCannotOpen
        }

        var entryCount = 0
        var expandedBytes: UInt64 = 0

        for entry in archive {
            entryCount += 1
            expandedBytes += UInt64(entry.uncompressedSize)

            guard
                entryCount <= maximumEntries,
                expandedBytes <= maximumExpandedBytes
            else {
                throw EPUBLoadingError.archiveTooLarge
            }

            let destination = try safeURL(
                forRelativePath: entry.path,
                inside: root
            )

            switch entry.type {
            case .file:
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try archive.extract(entry, to: destination)
            case .directory:
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            case .symlink:
                throw EPUBLoadingError.symbolicLinkNotAllowed(entry.path)
            }
        }
    }

    private static func safeURL(
        forRelativePath relativePath: String,
        inside root: URL
    ) throws -> URL {
        guard
            !relativePath.hasPrefix("/"),
            !relativePath.hasPrefix("\\"),
            !relativePath.split(separator: "/").contains(".."),
            !relativePath.split(separator: "\\").contains("..")
        else {
            throw EPUBLoadingError.unsafeArchivePath(relativePath)
        }

        let standardizedRoot = root.standardizedFileURL
        let candidate = root
            .appending(path: relativePath)
            .standardizedFileURL
        let rootPath = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"

        guard candidate.path.hasPrefix(rootPath) else {
            throw EPUBLoadingError.unsafeArchivePath(relativePath)
        }

        return candidate
    }
}

private struct EPUBManifestItem {
    let id: String
    let href: String
    let mediaType: String
    let properties: Set<String>
}

private struct EPUBPackage {
    var title: String?
    var author: String?
    var coverID: String?
    var manifest: [EPUBManifestItem] = []
    var spine: [String] = []
}

private struct EPUBRawNavigationItem {
    let title: String
    let href: String
    let depth: Int
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    private var packagePath: String?

    func packagePath(in data: Data) -> String? {
        packagePath = nil
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return packagePath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "rootfile" || elementName.hasSuffix(":rootfile") {
            packagePath = attributeDict["full-path"]
        }
    }
}

private final class EPUBPackageParser: NSObject, XMLParserDelegate {
    private var package = EPUBPackage()
    private var activeTextElement: String?
    private var textBuffer = ""

    func parse(_ data: Data) -> EPUBPackage {
        package = EPUBPackage()
        activeTextElement = nil
        textBuffer = ""
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return package
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init)
            ?? elementName

        switch localName {
        case "title", "creator":
            activeTextElement = localName
            textBuffer = ""
        case "item":
            guard
                let id = attributeDict["id"],
                let href = attributeDict["href"]
            else {
                return
            }
            let properties = Set(
                (attributeDict["properties"] ?? "")
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
            )
            package.manifest.append(
                EPUBManifestItem(
                    id: id,
                    href: href,
                    mediaType: attributeDict["media-type"] ?? "",
                    properties: properties
                )
            )
        case "itemref":
            if let idref = attributeDict["idref"] {
                package.spine.append(idref)
            }
        case "meta":
            if attributeDict["name"] == "cover" {
                package.coverID = attributeDict["content"]
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeTextElement != nil {
            textBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init)
            ?? elementName
        guard activeTextElement == localName else { return }

        switch localName {
        case "title":
            if package.title == nil {
                package.title = textBuffer
            }
        case "creator":
            if package.author == nil {
                package.author = textBuffer
            }
        default:
            break
        }

        activeTextElement = nil
        textBuffer = ""
    }
}

private final class EPUBNavigationParser: NSObject, XMLParserDelegate {
    private var items: [EPUBRawNavigationItem] = []
    private var elementDepth = 0
    private var tableOfContentsDepth: Int?
    private var listDepth = 0
    private var activeHref: String?
    private var activeTitle = ""
    private var activeDepth = 0

    func parse(_ data: Data) -> [EPUBRawNavigationItem] {
        items = []
        elementDepth = 0
        tableOfContentsDepth = nil
        listDepth = 0
        activeHref = nil
        activeTitle = ""
        activeDepth = 0

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementDepth += 1
        let localName = elementName.split(separator: ":").last.map(String.init)
            ?? elementName

        if localName == "nav", tableOfContentsDepth == nil {
            let type = attributeDict.first {
                $0.key == "epub:type" || $0.key.hasSuffix(":type")
            }?.value
            if
                type?.split(whereSeparator: \.isWhitespace)
                    .contains("toc") == true
                    || attributeDict["role"] == "doc-toc"
            {
                tableOfContentsDepth = elementDepth
            }
        }

        guard tableOfContentsDepth != nil else { return }
        if localName == "ol" {
            listDepth += 1
        } else if localName == "a", let href = attributeDict["href"] {
            activeHref = href
            activeTitle = ""
            activeDepth = max(listDepth - 1, 0)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeHref != nil {
            activeTitle += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init)
            ?? elementName

        if localName == "a", let activeHref {
            items.append(
                EPUBRawNavigationItem(
                    title: activeTitle,
                    href: activeHref,
                    depth: activeDepth
                )
            )
            self.activeHref = nil
            activeTitle = ""
        }

        if tableOfContentsDepth != nil, localName == "ol" {
            listDepth = max(listDepth - 1, 0)
        }
        if
            localName == "nav",
            tableOfContentsDepth == elementDepth
        {
            tableOfContentsDepth = nil
        }
        elementDepth = max(elementDepth - 1, 0)
    }
}

private final class EPUBNCXParser: NSObject, XMLParserDelegate {
    private struct Point {
        let sequence: Int
        let depth: Int
        var title = ""
        var href: String?
        var capturesTitle = false
    }

    private var completed: [(sequence: Int, item: EPUBRawNavigationItem)] = []
    private var stack: [Point] = []
    private var nextSequence = 0

    func parse(_ data: Data) -> [EPUBRawNavigationItem] {
        completed = []
        stack = []
        nextSequence = 0
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return completed
            .sorted { $0.sequence < $1.sequence }
            .map(\.item)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init)
            ?? elementName

        switch localName {
        case "navPoint":
            stack.append(
                Point(sequence: nextSequence, depth: stack.count)
            )
            nextSequence += 1
        case "text":
            if !stack.isEmpty {
                stack[stack.count - 1].capturesTitle = true
            }
        case "content":
            if !stack.isEmpty {
                stack[stack.count - 1].href = attributeDict["src"]
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty, stack[stack.count - 1].capturesTitle else {
            return
        }
        stack[stack.count - 1].title += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init)
            ?? elementName
        if localName == "text", !stack.isEmpty {
            stack[stack.count - 1].capturesTitle = false
        } else if localName == "navPoint", let point = stack.popLast() {
            guard let href = point.href else { return }
            completed.append(
                (
                    point.sequence,
                    EPUBRawNavigationItem(
                        title: point.title,
                        href: href,
                        depth: point.depth
                    )
                )
            )
        }
    }
}

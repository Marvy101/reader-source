import Foundation

enum XHTMLTextExtractor {
    static func extract(from url: URL) -> (title: String?, text: String) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return (nil, "")
        }

        let delegate = XHTMLTextParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (
            delegate.title?.normalizedReaderWhitespace.nilIfEmpty,
            delegate.text.normalizedReaderWhitespace
        )
    }
}

enum ReflowablePageEstimator {
    // EPUB has no fixed pages. This gives the library one stable, device-neutral
    // definition instead of changing the count with every window or font size.
    static let wordsPerPage = 275

    static func estimate(resources: [EPUBResource]) -> Int {
        let wordCount = resources.reduce(into: 0) { total, resource in
            total += countWords(
                in: XHTMLTextExtractor.extract(from: resource.fileURL).text
            )
        }
        return estimate(wordCount: wordCount)
    }

    static func estimate(wordCount: Int) -> Int {
        max(1, (wordCount + wordsPerPage - 1) / wordsPerPage)
    }

    private static func countWords(in text: String) -> Int {
        var count = 0
        var isInsideWord = false

        for character in text {
            if character.isWhitespace {
                isInsideWord = false
            } else if !isInsideWord {
                count += 1
                isInsideWord = true
            }
        }

        return count
    }
}

private final class XHTMLTextParserDelegate: NSObject, XMLParserDelegate {
    var title: String?
    var text = ""

    private var ignoredDepth = 0
    private var headingDepth = 0
    private var headingBuffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init)
            ?? elementName

        if ["script", "style", "head"].contains(name) {
            ignoredDepth += 1
            return
        }
        guard ignoredDepth == 0 else { return }

        if ["h1", "h2", "h3", "title"].contains(name), title == nil {
            headingDepth += 1
            headingBuffer = ""
        }

        if ["p", "div", "section", "article", "li", "blockquote", "br"].contains(name) {
            text += "\n"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard ignoredDepth == 0 else { return }
        text += string
        if headingDepth > 0 {
            headingBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init)
            ?? elementName

        if ["script", "style", "head"].contains(name) {
            ignoredDepth = max(ignoredDepth - 1, 0)
            return
        }
        guard ignoredDepth == 0 else { return }

        if ["h1", "h2", "h3", "title"].contains(name), headingDepth > 0 {
            headingDepth -= 1
            if headingDepth == 0, title == nil {
                title = headingBuffer
            }
        }

        if ["p", "div", "section", "article", "li", "blockquote"].contains(name) {
            text += "\n"
        }
    }
}

extension String {
    var normalizedReaderWhitespace: String {
        replacingOccurrences(
            of: #"[ \t\r\f\v]+"#,
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\n\s*\n+"#,
            with: "\n\n",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

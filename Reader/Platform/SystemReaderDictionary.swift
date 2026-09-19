import Foundation

#if os(macOS)
import CoreServices
#endif

struct ReaderDictionaryTerm: Equatable, Sendable {
    let value: String

    init?(_ rawValue: String) {
        let edgeCharacters = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
        let normalized = rawValue
            .trimmingCharacters(in: edgeCharacters)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )

        guard !normalized.isEmpty, normalized.count <= 80 else { return nil }
        value = normalized
    }

    var isSingleWord: Bool {
        !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

struct ReaderDictionaryEntry: Equatable, Sendable {
    let term: String
    let definition: String
    let presentation: ReaderDictionaryPresentation

    init(term: String, definition: String) {
        self.term = term
        self.definition = definition
        presentation = ReaderDictionaryPresentationParser.parse(
            term: term,
            definition: definition
        )
    }
}

struct ReaderDictionaryPresentation: Equatable, Sendable {
    let variant: String?
    let pronunciations: [String]
    let sections: [ReaderDictionarySection]
}

struct ReaderDictionarySection: Equatable, Identifiable, Sendable {
    let id: Int
    let title: String
    let body: String
}

enum ReaderDictionaryPresentationParser {
    private static let partOfSpeechPattern =
        #"pronoun|preposition|conjunction|determiner|exclamation|adjective|adverb|noun|verb"#
    private static let sectionPattern =
        #"(^|\.\s+)(PHRASAL VERBS|PHRASES|DERIVATIVES|ORIGIN|USAGE|pronoun|preposition|conjunction|determiner|exclamation|adjective|adverb|noun|verb)\b"#

    static func parse(term: String, definition: String) -> ReaderDictionaryPresentation {
        let normalized = definition.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let pronunciations = pronunciationCandidates(in: String(normalized.prefix(220)))

        guard let firstPartOfSpeech = firstPartOfSpeechRange(
            in: normalized,
            after: term
        ) else {
            return ReaderDictionaryPresentation(
                variant: nil,
                pronunciations: pronunciations,
                sections: [
                    ReaderDictionarySection(
                        id: 0,
                        title: "definition",
                        body: formatBody(normalized, pronunciations: pronunciations)
                    )
                ]
            )
        }

        let header = String(normalized[..<firstPartOfSpeech.lowerBound])
        let body = String(normalized[firstPartOfSpeech.lowerBound...])
        let parsedSections = sections(in: body, pronunciations: pronunciations)

        return ReaderDictionaryPresentation(
            variant: variant(in: header, term: term, pronunciations: pronunciations),
            pronunciations: pronunciations,
            sections: parsedSections.isEmpty
                ? [
                    ReaderDictionarySection(
                        id: 0,
                        title: "definition",
                        body: formatBody(body, pronunciations: pronunciations)
                    )
                ]
                : parsedSections
        )
    }

    private static func firstPartOfSpeechRange(
        in definition: String,
        after term: String
    ) -> Range<String.Index>? {
        let searchStart = definition.index(
            definition.startIndex,
            offsetBy: min(term.count, definition.count)
        )
        let prefixEnd = definition.index(
            searchStart,
            offsetBy: min(180, definition.distance(from: searchStart, to: definition.endIndex))
        )
        return definition.range(
            of: partOfSpeechPattern,
            options: .regularExpression,
            range: searchStart..<prefixEnd
        )
    }

    private static func pronunciationCandidates(in prefix: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\|\s*([^|]{1,32}?)\s*\|"#
        ) else { return [] }

        let range = NSRange(prefix.startIndex..., in: prefix)
        var seen = Set<String>()
        return regex.matches(in: prefix, range: range).compactMap { match in
            guard
                let candidateRange = Range(match.range(at: 1), in: prefix)
            else { return nil }
            let candidate = prefix[candidateRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !candidate.isEmpty,
                candidate.split(separator: " ").count <= 4,
                candidate.range(of: #"[:;.•]"#, options: .regularExpression) == nil,
                seen.insert(candidate).inserted
            else { return nil }
            return candidate
        }
    }

    private static func variant(
        in header: String,
        term: String,
        pronunciations: [String]
    ) -> String? {
        var value = header
        if value.lowercased().hasPrefix(term.lowercased()) {
            value.removeFirst(min(term.count, value.count))
        }
        value = removePronunciations(from: value, pronunciations: pronunciations)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, Int(value) == nil else { return nil }
        return value
    }

    private static func sections(
        in body: String,
        pronunciations: [String]
    ) -> [ReaderDictionarySection] {
        guard let regex = try? NSRegularExpression(pattern: sectionPattern) else {
            return []
        }
        let bodyRange = NSRange(body.startIndex..., in: body)
        let matches = regex.matches(in: body, range: bodyRange)
        guard !matches.isEmpty else { return [] }

        return matches.enumerated().compactMap { index, match in
            guard
                let titleRange = Range(match.range(at: 2), in: body),
                let contentStart = Range(match.range(at: 2), in: body)?.upperBound
            else { return nil }

            let contentEnd: String.Index
            if index + 1 < matches.count {
                let next = matches[index + 1]
                guard let nextRange = Range(next.range, in: body) else { return nil }
                if next.range(at: 1).length > 0 {
                    contentEnd = body.index(after: nextRange.lowerBound)
                } else {
                    contentEnd = nextRange.lowerBound
                }
            } else {
                contentEnd = body.endIndex
            }

            let content = String(body[contentStart..<contentEnd])
            return ReaderDictionarySection(
                id: index,
                title: body[titleRange].lowercased(),
                body: formatBody(content, pronunciations: pronunciations)
            )
        }
    }

    private static func formatBody(
        _ body: String,
        pronunciations: [String]
    ) -> String {
        removePronunciations(from: body, pronunciations: pronunciations)
            .replacingOccurrences(of: " • ", with: "\n\n• ")
            .replacingOccurrences(
                of: #"\. ([2-9][0-9]?) "#,
                with: ".\n\n$1 ",
                options: .regularExpression
            )
            .replacingOccurrences(of: " | ", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removePronunciations(
        from value: String,
        pronunciations: [String]
    ) -> String {
        pronunciations.reduce(value) { result, pronunciation in
            result.replacingOccurrences(of: "| \(pronunciation) |", with: "")
                .replacingOccurrences(of: "|\(pronunciation)|", with: "")
        }
    }
}

protocol ReaderDictionaryLookingUp: Sendable {
    func definition(for term: ReaderDictionaryTerm) -> ReaderDictionaryEntry?
}

struct SystemReaderDictionary: ReaderDictionaryLookingUp {
    func definition(for term: ReaderDictionaryTerm) -> ReaderDictionaryEntry? {
        #if os(macOS)
        let source = term.value as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(source))
        guard let result = DCSCopyTextDefinition(nil, source, range) else {
            return nil
        }
        let definition = result.takeRetainedValue() as String
        guard !definition.isEmpty else { return nil }
        return ReaderDictionaryEntry(term: term.value, definition: definition)
        #else
        return nil
        #endif
    }
}

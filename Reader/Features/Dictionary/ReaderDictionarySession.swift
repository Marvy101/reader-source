import Foundation
import Observation

struct ReaderDictionarySessionSnapshot: Codable, Equatable, Sendable {
    let searchText: String
    let preservesManualLookup: Bool
    let lookupWasAttempted: Bool
}

@MainActor
@Observable
final class ReaderDictionarySession {
    var searchText: String
    private(set) var entry: ReaderDictionaryEntry?
    private(set) var preservesManualLookup: Bool
    private(set) var lookupWasAttempted: Bool
    @ObservationIgnored var onStateChanged: (() -> Void)?

    @ObservationIgnored private let dictionary = SystemReaderDictionary()

    init(searchText: String = "", preservesManualLookup: Bool = true) {
        self.searchText = searchText
        self.preservesManualLookup = preservesManualLookup
        lookupWasAttempted = !searchText.isEmpty
        entry = Self.lookup(searchText, using: dictionary)
    }

    init(snapshot: ReaderDictionarySessionSnapshot) {
        searchText = snapshot.searchText
        preservesManualLookup = snapshot.preservesManualLookup
        lookupWasAttempted = snapshot.lookupWasAttempted
        entry = snapshot.lookupWasAttempted
            ? Self.lookup(snapshot.searchText, using: dictionary)
            : nil
    }

    var snapshot: ReaderDictionarySessionSnapshot {
        ReaderDictionarySessionSnapshot(
            searchText: searchText,
            preservesManualLookup: preservesManualLookup,
            lookupWasAttempted: lookupWasAttempted
        )
    }

    var canReceiveSelectionLookup: Bool {
        !preservesManualLookup
    }

    func showSelectionLookup(_ term: ReaderDictionaryTerm) {
        searchText = term.value
        entry = dictionary.definition(for: term)
        preservesManualLookup = false
        lookupWasAttempted = true
        onStateChanged?()
    }

    func updateSearchTextFromUser(_ value: String) {
        guard value != searchText else { return }

        searchText = value
        entry = nil
        preservesManualLookup = true
        lookupWasAttempted = false
        onStateChanged?()
    }

    func submitManualLookup() {
        entry = Self.lookup(searchText, using: dictionary)
        preservesManualLookup = true
        lookupWasAttempted = true
        onStateChanged?()
    }

    private static func lookup(
        _ rawValue: String,
        using dictionary: SystemReaderDictionary
    ) -> ReaderDictionaryEntry? {
        guard let term = ReaderDictionaryTerm(rawValue) else { return nil }
        return dictionary.definition(for: term)
    }
}

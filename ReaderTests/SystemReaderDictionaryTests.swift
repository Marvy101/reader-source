import XCTest
@testable import Reader

final class SystemReaderDictionaryTests: XCTestCase {
    func testSingleWordSelectionOffersDefinitionWithoutAIRewrite() {
        let availability = ReaderSelectionActionAvailability(
            selectedText: "serendipity"
        )

        XCTAssertTrue(availability.canDefine)
        XCTAssertFalse(availability.canRewriteWithAI)
    }

    func testPassageSelectionOffersAIRewriteWithoutDefinition() {
        let availability = ReaderSelectionActionAvailability(
            selectedText: "For the grand finale, we imagined a different ending."
        )

        XCTAssertFalse(availability.canDefine)
        XCTAssertTrue(availability.canRewriteWithAI)
    }

    func testDictionaryTermTrimsSelectionPunctuation() throws {
        let term = try XCTUnwrap(ReaderDictionaryTerm("  serendipity.\n"))

        XCTAssertEqual(term.value, "serendipity")
        XCTAssertTrue(term.isSingleWord)
    }

    func testDictionaryTermPreservesACompactPhrase() throws {
        let term = try XCTUnwrap(ReaderDictionaryTerm("state of the art"))

        XCTAssertEqual(term.value, "state of the art")
        XCTAssertFalse(term.isSingleWord)
    }

    func testDictionaryTermRejectsEmptyAndOversizedSelections() {
        XCTAssertNil(ReaderDictionaryTerm("  …  "))
        XCTAssertNil(ReaderDictionaryTerm(String(repeating: "a", count: 81)))
    }

    func testAutomaticLookupWaitsForAStableWordSelection() throws {
        var gate = ReaderSelectionAutomaticLookupGate(
            stabilizationInterval: 0.35
        )
        let selection = readerSelection("serendipity")

        XCTAssertNil(gate.observe(selection, at: 0))
        XCTAssertNil(gate.observe(selection, at: 0.2))

        let term = try XCTUnwrap(gate.observe(selection, at: 0.36))
        XCTAssertEqual(term.value, "serendipity")
        XCTAssertNil(gate.observe(selection, at: 1))
    }

    func testParagraphDragNeverLooksUpItsIntermediateWord() throws {
        var gate = ReaderSelectionAutomaticLookupGate(
            stabilizationInterval: 0.35
        )

        XCTAssertNil(gate.observe(readerSelection("For"), at: 0))
        XCTAssertNil(gate.observe(readerSelection("For the"), at: 0.1))
        XCTAssertNil(
            gate.observe(
                readerSelection("For the grand finale, we imagined a different ending."),
                at: 0.6
            )
        )

        XCTAssertNil(gate.observe(nil, at: 0.7))
        let newWord = readerSelection("grand")
        XCTAssertNil(gate.observe(newWord, at: 0.8))
        XCTAssertEqual(
            try XCTUnwrap(gate.observe(newWord, at: 1.16)).value,
            "grand"
        )
    }

    func testDefaultRewriteCommandRequestsOnlySimplifiedPassage() {
        let command = ReaderRewriteCommand()

        XCTAssertNil(command.instruction)
        XCTAssertNil(command.currentDraft)
        XCTAssertEqual(
            command.question,
            "Rewrite this passage in simpler terms. Return only the rewritten passage."
        )
    }

    func testOneTimeRewriteInstructionIncludesCurrentDraftWithoutPersistingIt() {
        let command = ReaderRewriteCommand(
            instruction: "  make this more lyrical  ",
            currentDraft: "  A simpler first rewrite.  "
        )

        XCTAssertEqual(command.instruction, "make this more lyrical")
        XCTAssertEqual(command.currentDraft, "A simpler first rewrite.")
        XCTAssertTrue(command.question.contains("make this more lyrical"))
        XCTAssertTrue(command.question.contains("A simpler first rewrite."))
        XCTAssertTrue(command.question.contains("one-time instruction"))
        XCTAssertTrue(command.question.hasSuffix("Do not describe the changes."))
    }

#if DEBUG
    func testInlineRewritePreviewCanApplyOneTimeConciseInstruction() {
        let response = ReaderInlineRewritePreview.response(
            for: "The first sentence carries the idea. The second sentence is detail.",
            command: ReaderRewriteCommand(instruction: "make it shorter")
        )

        XCTAssertEqual(response, "The first sentence carries the idea.")
    }
#endif

    func testSystemDictionaryReturnsACompleteEntryWhenDefinitionIsInstalled() throws {
        let term = try XCTUnwrap(ReaderDictionaryTerm("serendipity"))
        guard let entry = SystemReaderDictionary().definition(for: term) else {
            throw XCTSkip("The test Mac has no active English definition dictionary.")
        }

        XCTAssertEqual(entry.term, "serendipity")
        XCTAssertFalse(entry.definition.isEmpty)
    }

    func testPresentationSeparatesPronunciationPartsOfSpeechAndReferenceSections() {
        let presentation = ReaderDictionaryPresentationParser.parse(
            term: "page",
            definition: "page 1 | pāj | noun one side of a sheet: a printed page. • Computing a section of stored data. verb [with object] divide content into pages. PHRASES on the same page in agreement. DERIVATIVES paged | pājd | adjective. ORIGIN from Latin pagina."
        )

        XCTAssertNil(presentation.variant)
        XCTAssertEqual(presentation.pronunciations, ["pāj", "pājd"])
        XCTAssertEqual(
            presentation.sections.map(\.title),
            ["noun", "verb", "phrases", "derivatives", "origin"]
        )
        XCTAssertTrue(presentation.sections[0].body.contains("\n\n• Computing"))
    }

    func testPresentationHandlesSyllabificationJoinedToPartOfSpeech() {
        let presentation = ReaderDictionaryPresentationParser.parse(
            term: "record",
            definition: "record rec·ordnoun | ˈrekərd | 1 a written account. verb [with object] | rəˈkôrd | set down in permanent form. ORIGIN from Latin recordari."
        )

        XCTAssertEqual(presentation.variant, "rec·ord")
        XCTAssertEqual(presentation.pronunciations, ["ˈrekərd", "rəˈkôrd"])
        XCTAssertEqual(presentation.sections.map(\.title), ["noun", "verb", "origin"])
        XCTAssertEqual(presentation.sections[0].body, "1 a written account.")
    }

    private func readerSelection(_ text: String) -> ReaderSelection {
        ReaderSelection(
            locator: ReaderLocator(
                publicationFingerprint: "dictionary-tests",
                resourceID: "chapter-1",
                position: 0,
                progression: 0
            ),
            selectedText: text
        )
    }
}

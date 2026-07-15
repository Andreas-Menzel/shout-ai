// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

final class TextNormalizerTests: XCTestCase {

    // MARK: wordParts

    func testWordPartsSplitsCompoundIdentifiers() {
        XCTAssertEqual(TextNormalizer.wordParts(of: "openSOURCE"), ["open", "SOURCE"])
        XCTAssertEqual(TextNormalizer.wordParts(of: "HTTPServer"), ["HTTP", "Server"])
        XCTAssertEqual(TextNormalizer.wordParts(of: "CameraGPS"), ["Camera", "GPS"])
        XCTAssertEqual(TextNormalizer.wordParts(of: "HTTPApp"), ["HTTP", "App"])
    }

    func testWordPartsHandlesSeparatorsAndDigits() {
        XCTAssertEqual(TextNormalizer.wordParts(of: "some_thing-here now"), ["some", "thing", "here", "now"])
        XCTAssertEqual(TextNormalizer.wordParts(of: "Route66"), ["Route", "66"])
        XCTAssertEqual(TextNormalizer.wordParts(of: "v2Ready"), ["v", "2", "Ready"])
    }

    func testSpacedForm() {
        XCTAssertEqual(TextNormalizer.spacedForm(of: "HTTPServer"), "HTTP Server")
        XCTAssertEqual(TextNormalizer.spacedForm(of: "Camera"), "Camera")
    }

    // MARK: glossary

    func testApplyGlossaryFixesSpacingAndCasing() {
        XCTAssertEqual(
            TextNormalizer.applyGlossary("we use http server daily", glossary: ["HTTPServer"]),
            "we use HTTPServer daily")
        XCTAssertEqual(
            TextNormalizer.applyGlossary("Ich nutze HTTP Server", glossary: ["HTTPServer"]),
            "Ich nutze HTTPServer")
    }

    func testApplyGlossaryIsWordBoundaryAnchored() {
        // Must not rewrite a substring inside a larger word.
        XCTAssertEqual(
            TextNormalizer.applyGlossary("openSOURCEX stays", glossary: ["openSOURCE"]),
            "openSOURCEX stays")
    }

    func testApplyGlossaryLongestTermWins() {
        // "HTTPServer" should win over "HTTP" so the compound isn't half-matched.
        let out = TextNormalizer.applyGlossary("http server", glossary: ["HTTP", "HTTPServer"])
        XCTAssertEqual(out, "HTTPServer")
    }

    func testApplyGlossaryEmptyInputsAreSafe() {
        XCTAssertEqual(TextNormalizer.applyGlossary("", glossary: ["HTTPServer"]), "")
        XCTAssertEqual(TextNormalizer.applyGlossary("nothing here", glossary: []), "nothing here")
    }

    // MARK: fillers

    func testStripFillersRemovesHesitations() {
        XCTAssertEqual(TextNormalizer.stripFillers("das äh Update"), "das Update")
        XCTAssertEqual(TextNormalizer.stripFillers("Ähm, also los"), "also los")
    }

    func testStripFillersKeepsRealWords() {
        // "um" is a real German preposition and must survive.
        XCTAssertEqual(TextNormalizer.stripFillers("wir treffen uns um zehn"), "wir treffen uns um zehn")
    }

    func testStripFillersRepairsPunctuationSpacing() {
        XCTAssertEqual(TextNormalizer.stripFillers("gut äh , oder"), "gut, oder")
    }

    // MARK: normalize (end to end)

    func testNormalizeCombinesFillerStripAndGlossary() {
        XCTAssertEqual(
            TextNormalizer.normalize("Ähm, wir nutzen http server", glossary: ["HTTPServer"]),
            "wir nutzen HTTPServer")
    }

    // MARK: newline / markdown preservation

    func testTidySpacingPreservesBlankAndSingleLineBreaks() {
        // Blank lines separate markdown blocks; single newlines separate list
        // items. Both must survive — the old `\s{2,}` collapse ate blank lines,
        // welding a heading onto the previous line.
        let md = "# Title\n\n* one\n* two\n\n## Section\n\n* three"
        XCTAssertEqual(TextNormalizer.tidySpacing(md), md)
    }

    func testTidySpacingCollapsesHorizontalRunsOnly() {
        XCTAssertEqual(TextNormalizer.tidySpacing("a  b\nc   d\n\ne"), "a b\nc d\n\ne")
    }

    func testTidySpacingKeepsNewlineBeforePunctuation() {
        // A horizontal space before punctuation is removed; a newline is not.
        XCTAssertEqual(TextNormalizer.tidySpacing("word .\ntext"), "word.\ntext")
        XCTAssertEqual(TextNormalizer.tidySpacing("word\n: text"), "word\n: text")
    }

    func testTidySpacingCapsRunawayBlankLines() {
        XCTAssertEqual(TextNormalizer.tidySpacing("a\n\n\n\nb"), "a\n\nb")
    }

    func testNormalizeKeepsMarkdownStructureWhileFixingGlossary() {
        // End to end: the rewrite's markdown survives normalization while the
        // glossary casing/spacing fix still lands.
        let input = "# Overview\n\n* We use HTTP Server daily.\n\n## Details\n\n* It syncs fast."
        let expected = "# Overview\n\n* We use HTTPServer daily.\n\n## Details\n\n* It syncs fast."
        XCTAssertEqual(TextNormalizer.normalize(input, glossary: ["HTTPServer"]), expected)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

final class WhisperTidyTests: XCTestCase {

    func testTidyRemovesBracketedArtifacts() {
        XCTAssertEqual(WhisperTranscriber.tidy("[BLANK_AUDIO] hello"), "hello")
        XCTAssertEqual(WhisperTranscriber.tidy("(Musik) los geht's"), "los geht's")
        XCTAssertEqual(WhisperTranscriber.tidy("la la \u{266A}\u{266A}"), "la la")
    }

    func testTidyCollapsesWhitespace() {
        // tidy() collapses any run of 2+ whitespace into a single space.
        XCTAssertEqual(WhisperTranscriber.tidy("a    b   c"), "a b c")
        XCTAssertEqual(WhisperTranscriber.tidy("a \t b"), "a b")
    }

    func testTidyTrims() {
        XCTAssertEqual(WhisperTranscriber.tidy("  hello  "), "hello")
    }

    func testHallucinationDenylistIsLowercased() {
        // The pipeline compares `cleaned.lowercased()` against this set, so every
        // entry must be lowercase or it can never match.
        for phrase in WhisperTranscriber.hallucinations {
            XCTAssertEqual(phrase, phrase.lowercased(), "hallucination entry must be lowercase: \(phrase)")
        }
        XCTAssertTrue(WhisperTranscriber.hallucinations.contains("thanks for watching!"))
    }
}

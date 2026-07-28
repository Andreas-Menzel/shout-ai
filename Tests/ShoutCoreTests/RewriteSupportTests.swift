// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

// Shared prompt/guard logic: `RewriteSupport` (endsWithQuestion, postprocess)
// backs every engine; `GuardrailSettings.approve` is the per-profile guard.
final class RewriteSupportTests: XCTestCase {

    // MARK: endsWithQuestion

    func testEndsWithQuestion() {
        XCTAssertTrue(RewriteSupport.endsWithQuestion("Stimmt das?"))
        XCTAssertTrue(RewriteSupport.endsWithQuestion("Stimmt das?   "))
        XCTAssertTrue(RewriteSupport.endsWithQuestion("\u{201E}Oder?\u{201C}"))   // wrapped in German quotes
        XCTAssertFalse(RewriteSupport.endsWithQuestion("Das ist gut."))
        XCTAssertFalse(RewriteSupport.endsWithQuestion(""))
    }

    // MARK: guardrails — strict (Clean-up) profile

    func testStrictGuardsAcceptModestEdits() {
        XCTAssertTrue(GuardrailSettings.strict.approve(
            cleaned: "Ich glaube, wir sollten das jetzt wirklich machen, oder",
            original: "also ich glaube wir sollten das jetzt wirklich mal machen oder"))
    }

    func testStrictGuardsRejectDroppedSentence() {
        XCTAssertFalse(GuardrailSettings.strict.approve(
            cleaned: "one two three",   // ratio 0.3 < 0.5
            original: "one two three four five six seven eight nine ten"))
    }

    func testStrictGuardsRejectBallooning() {
        XCTAssertFalse(GuardrailSettings.strict.approve(
            cleaned: "one two three four five six seven",   // ratio 1.75 > 1.5
            original: "one two three four"))
    }

    func testStrictGuardsRejectLostTrailingQuestion() {
        XCTAssertFalse(GuardrailSettings.strict.approve(
            cleaned: "Wir machen das morgen.", original: "wir machen das morgen, oder?"))
    }

    func testStrictGuardsEmptyOriginalIsTrusted() {
        XCTAssertTrue(GuardrailSettings.strict.approve(cleaned: "", original: ""))
    }

    // MARK: guardrails — toggled off (Summarize / Translate)

    func testRatioGuardOffAllowsBigShrink() {
        let summarize = GuardrailSettings(
            lengthRatioGuard: false, preserveTrailingQuestions: false,
            enforceSameLanguage: true, actAsAssistant: false)
        XCTAssertTrue(summarize.approve(
            cleaned: "Meet at eleven.",
            original: "so um we should probably meet at eleven at the station and I will bring the documents"))
    }

    func testTrailingQuestionGuardOffAllowsDrop() {
        let relaxed = GuardrailSettings(
            lengthRatioGuard: false, preserveTrailingQuestions: false,
            enforceSameLanguage: false, actAsAssistant: false)
        XCTAssertTrue(relaxed.approve(cleaned: "We ship tomorrow.", original: "we ship tomorrow, oder?"))
    }

    // MARK: postprocess

    func testPostprocessStripsEchoedLabel() {
        XCTAssertEqual(RewriteSupport.postprocess("Output: Das Update läuft."), "Das Update läuft.")
        XCTAssertEqual(RewriteSupport.postprocess("Cleaned: Das Update läuft."), "Das Update läuft.")
        XCTAssertEqual(RewriteSupport.postprocess("bereinigt: Alles gut."), "Alles gut.")
    }

    func testPostprocessStripsWrappingQuotes() {
        XCTAssertEqual(RewriteSupport.postprocess("\"Hello there.\""), "Hello there.")
        XCTAssertEqual(RewriteSupport.postprocess("\u{201E}Hallo.\u{201C}"), "Hallo.")
    }

    func testPostprocessTrims() {
        XCTAssertEqual(RewriteSupport.postprocess("   spaced out   "), "spaced out")
    }

    func testPostprocessStripsCodeFence() {
        XCTAssertEqual(RewriteSupport.postprocess("```\nDas Update läuft.\n```"), "Das Update läuft.")
        XCTAssertEqual(RewriteSupport.postprocess("```text\nHello there.\n```"), "Hello there.")
        XCTAssertEqual(RewriteSupport.postprocess("```hi```"), "hi")
        // Backticks inside the text are not a fence and stay.
        XCTAssertEqual(RewriteSupport.postprocess("use `foo` here"), "use `foo` here")
    }

    // MARK: languageName

    func testLanguageNameCoversWhisperCodes() {
        XCTAssertEqual(RewriteSupport.languageName(for: "de"), "German")
        XCTAssertEqual(RewriteSupport.languageName(for: "en"), "English")
        XCTAssertEqual(RewriteSupport.languageName(for: "fr"), "French")
        XCTAssertEqual(RewriteSupport.languageName(for: "es"), "Spanish")
        XCTAssertNil(RewriteSupport.languageName(for: nil))
        XCTAssertNil(RewriteSupport.languageName(for: ""))
    }
}

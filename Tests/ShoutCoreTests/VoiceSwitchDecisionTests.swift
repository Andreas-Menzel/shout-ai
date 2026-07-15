// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

/// The live-selection contract: what the pill shows at key release is what
/// runs, in both directions, and the final transcript only contributes content.
final class VoiceSwitchDecisionTests: XCTestCase {
    private let profiles: [(id: String, name: String)] = [
        ("builtin-cleanup", "Clean-up"),
        ("builtin-professional", "Professional writing"),
        ("builtin-prompt-engineer", "Prompt engineer"),
        ("builtin-summarize", "Summarize"),
        ("builtin-translate-en", "Translate → English"),
    ]

    private func classify(_ transcript: String) -> VoiceCommand.Prefix {
        VoiceCommand.classifyPrefix(transcript: transcript, trigger: "use profile",
                                    cancelWords: ["cancel", "abbrechen"], profiles: profiles)
    }

    private func outcome(_ decision: VoiceSwitchDecision, _ transcript: String)
        -> VoiceSwitchDecision.ReleaseOutcome {
        decision.releaseOutcome(transcript: transcript, trigger: "use profile",
                                cancelWords: ["cancel", "abbrechen"], profiles: profiles)
    }

    // MARK: - State machine

    func testFollowsClassifierWhileFluid() {
        var d = VoiceSwitchDecision()
        XCTAssertEqual(d.state, .inactive)
        d.apply(classify("use profile"))
        XCTAssertEqual(d.state, .awaitingName)
        d.apply(classify("use profile xyzzy blah"))
        XCTAssertEqual(d.state, .unmatched(spoken: "xyzzy blah"))
        d.apply(classify("use profile xyzzy blah summarize"))
        XCTAssertEqual(d.state, .latched(profileID: "builtin-summarize", profileName: "Summarize"))
    }

    func testApplyReportsTheLatchExactlyOnce() {
        var d = VoiceSwitchDecision()
        XCTAssertFalse(d.apply(classify("use profile")))
        XCTAssertTrue(d.apply(classify("use profile summarize")))
        XCTAssertFalse(d.apply(classify("use profile summarize")))
    }

    func testLatchIsOneWay() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile summarize"))
        // Later decodes — garbled, a different profile, a cancel, silence —
        // must never move a shown badge.
        d.apply(classify("use profile summarized"))
        d.apply(classify("use profile clean"))
        d.apply(classify("use profile cancel"))
        d.apply(.none)
        XCTAssertEqual(d.state, .latched(profileID: "builtin-summarize", profileName: "Summarize"))
    }

    func testFreezeStopsAllUpdates() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile"))
        d.freeze()
        XCTAssertFalse(d.apply(classify("use profile summarize")))
        XCTAssertEqual(d.state, .awaitingName)
    }

    func testCancelledStaysFluidForRetrigger() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile xyzzy cancel"))
        XCTAssertEqual(d.state, .cancelled)
        d.apply(classify("use profile xyzzy cancel use profile summarize"))
        XCTAssertEqual(d.state, .latched(profileID: "builtin-summarize", profileName: "Summarize"))
    }

    // MARK: - Release outcome: not latched ⇒ never a switch

    func testInactiveInsertsVerbatimEvenWhenFinalContainsCommand() {
        // The contract's hard edge: the live pass never saw the command, so
        // the final transcript must not trigger a switch — or any stripping.
        let d = VoiceSwitchDecision()
        XCTAssertEqual(outcome(d, "Use profile summarize. Hello there."),
                       .dictation(text: "Use profile summarize. Hello there."))
    }

    func testAwaitingAtReleaseStripsCommandButDoesNotSwitch() {
        // Released before the badge appeared; the final decode heard a full
        // command. No switch — the words were command, not content, so they
        // are stripped and the notice explains.
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile"))
        d.freeze()
        XCTAssertEqual(outcome(d, "use profile two hello"),
                       .kept(content: "hello", notice: .releasedEarly))
    }

    func testAwaitingWithTriggerOnlyKeepsNothing() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile"))
        d.freeze()
        XCTAssertEqual(outcome(d, "use profile"),
                       .kept(content: "", notice: .releasedEarly))
    }

    func testUnmatchedAtReleaseEchoesTheSpokenWordsThePillShowed() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile xyzzy"))
        d.freeze()
        XCTAssertEqual(outcome(d, "use profile xyzzy"),
                       .kept(content: "", notice: .unknownName(spoken: "xyzzy")))
    }

    func testUnmatchedKeepsLongContentAfterTrigger() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile xyzzy hello there friend"))
        d.freeze()
        XCTAssertEqual(outcome(d, "use profile xyzzy hello there friend"),
                       .kept(content: "xyzzy hello there friend",
                             notice: .unknownName(spoken: "xyzzy hello")))
    }

    func testBareCancelNotices() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile cancel"))
        d.freeze()
        XCTAssertEqual(outcome(d, "use profile cancel"),
                       .kept(content: "", notice: .cancelled))
    }

    func testCancelWithRestKeepsDictationSilently() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile cancel"))
        d.freeze()
        XCTAssertEqual(outcome(d, "use profile cancel hello there"),
                       .kept(content: "hello there", notice: nil))
    }

    // MARK: - Release outcome: latched ⇒ that profile, always

    func testLatchedStripsAndSwitches() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile summarize"))
        d.freeze()
        XCTAssertEqual(
            outcome(d, "Use profile, summarize. Hello there, I am Andreas."),
            .switched(profileID: "builtin-summarize", profileName: "Summarize",
                      content: "Hello there, I am Andreas."))
    }

    func testLatchedBeatsADifferentFinalMatch() {
        // Decode drift turned the name into another profile's — the badge the
        // user saw wins; the final match only marks the boundary.
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile professional"))
        d.freeze()
        XCTAssertEqual(
            outcome(d, "use profile summarize hello"),
            .switched(profileID: "builtin-professional",
                      profileName: "Professional writing", content: "hello"))
    }

    func testLatchedSurvivesInflectedFinalName() {
        // Final decode heard "summarized" — strict grammar fails, the relaxed
        // re-match against the latched name recovers the boundary.
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile summarize"))
        d.freeze()
        XCTAssertEqual(
            outcome(d, "use profile summarized, hello there"),
            .switched(profileID: "builtin-summarize", profileName: "Summarize",
                      content: "hello there"))
    }

    func testLatchedSurvivesTypoedFinalName() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile summarize"))
        d.freeze()
        XCTAssertEqual(
            outcome(d, "use profile zummarize hello"),
            .switched(profileID: "builtin-summarize", profileName: "Summarize",
                      content: "hello"))
    }

    func testLatchedSurvivesGarbledTrigger() {
        // Even the trigger drifted in the final decode; the name alone
        // recovers the boundary.
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile summarize"))
        d.freeze()
        XCTAssertEqual(
            outcome(d, "news profile summarize hello there"),
            .switched(profileID: "builtin-summarize", profileName: "Summarize",
                      content: "hello there"))
    }

    func testLatchedMultiWordNameStripsWholeName() {
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile professional writing"))
        d.freeze()
        XCTAssertEqual(
            outcome(d, "use profile professional writing hello"),
            .switched(profileID: "builtin-professional",
                      profileName: "Professional writing", content: "hello"))
    }

    func testLatchedRelaxedMissKeepsFailedPathContent() {
        // Nothing in the final decode resembles the name — never drop content,
        // keep everything after the trigger even if a garble word rides along.
        var d = VoiceSwitchDecision()
        d.apply(classify("use profile summarize"))
        d.freeze()
        XCTAssertEqual(
            outcome(d, "use profile blah hello there friend"),
            .switched(profileID: "builtin-summarize", profileName: "Summarize",
                      content: "blah hello there friend"))
    }

    // MARK: - Relaxed matcher stays narrow

    func testRelaxedNeverStripsDeepIntoContent() {
        // The latched name appearing far past the command window is content,
        // not command — the relaxed matcher must not reach it.
        XCTAssertNil(VoiceCommand.relaxedRemainder(
            transcript: "use profile aa bb cc dd ee ff summarize it",
            trigger: "use profile", latchedName: "Summarize"))
    }

    func testRelaxedRejectsUnrelatedWords() {
        XCTAssertNil(VoiceCommand.relaxedRemainder(
            transcript: "use profile laptop hello",
            trigger: "use profile", latchedName: "Summarize"))
    }
}

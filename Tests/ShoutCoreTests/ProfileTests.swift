// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

final class ProfileTests: XCTestCase {

    func testCleanUpPromptHasScaffoldingTaskAndCue() {
        let (system, user) = Profile.cleanUp.buildPrompt(transcript: "hallo welt", languageCode: "de", glossary: [])
        XCTAssertTrue(system.contains("text filter, not an assistant"))
        XCTAssertTrue(system.contains("Never translate"))
        XCTAssertTrue(system.contains("Clean up the transcript"))
        XCTAssertTrue(user.contains("Transcript: hallo welt"))
        XCTAssertTrue(user.hasSuffix("Output:"))
        XCTAssertTrue(user.contains("in German"))   // language pin present
    }

    func testTranslateOmitsSameLanguageRuleAndPin() {
        let (system, user) = Profile.translateEnglish.buildPrompt(transcript: "hallo", languageCode: "de", glossary: [])
        XCTAssertFalse(system.contains("Never translate"))
        XCTAssertFalse(user.contains("in German"))   // no pin when enforceSameLanguage is off
        XCTAssertTrue(system.contains("Translate"))
    }

    func testLanguagePinCoversAllWhisperLanguages() {
        let (_, user) = Profile.cleanUp.buildPrompt(transcript: "bonjour", languageCode: "fr", glossary: [])
        XCTAssertTrue(user.contains("in French"))
        let (_, unknown) = Profile.cleanUp.buildPrompt(transcript: "x", languageCode: nil, glossary: [])
        XCTAssertFalse(unknown.contains("The transcript is in"))
    }

    func testAssistantModeDropsFilterFraming() {
        let (system, _) = Profile.promptEngineer.buildPrompt(transcript: "x", languageCode: "en", glossary: [])
        XCTAssertFalse(system.contains("text filter, not an assistant"))
        XCTAssertTrue(system.contains(RewriteSupport.outputOnlyLine))
    }

    func testRawPromptReplacesScaffolding() {
        let profile = Profile(id: "p", name: "Raw", taskPrompt: "ignored", rawPrompt: "DO THE THING", guardrails: .strict)
        let (system, _) = profile.buildPrompt(transcript: "x", languageCode: "en", glossary: [])
        XCTAssertTrue(system.hasPrefix("DO THE THING"))
        XCTAssertFalse(system.contains("text filter, not an assistant"))
        XCTAssertTrue(system.contains(RewriteSupport.outputOnlyLine))
    }

    func testGlossaryClauseConditional() {
        let (withTerms, _) = Profile.cleanUp.buildPrompt(transcript: "x", languageCode: "en", glossary: ["HTTPServer"])
        XCTAssertTrue(withTerms.contains("HTTPServer"))
        let (bare, _) = Profile.cleanUp.buildPrompt(transcript: "x", languageCode: "en", glossary: [])
        XCTAssertFalse(bare.contains("Glossary"))
    }

    func testGlossaryExampleIsBilingual() {
        let (system, _) = Profile.cleanUp.buildPrompt(
            transcript: "x", languageCode: "en", glossary: ["HTTPServer", "CameraGPS"])
        XCTAssertTrue(system.contains("Wir nutzen HTTP Server im Alltag."))     // spoken form, German line
        XCTAssertTrue(system.contains("Wir nutzen HTTPServer im Alltag."))      // canonical form
        XCTAssertTrue(system.contains("The Camera GPS rollout starts tomorrow."))
        XCTAssertTrue(system.contains("The CameraGPS rollout starts tomorrow."))
    }

    // MARK: - Built-in prompt upgrade path

    func testUpgradeReplacesUneditedOldBuiltIn() {
        var old = Profile.cleanUp
        old.taskPrompt = Profile.previousBuiltInTaskPrompts[Profile.cleanUpID]!.first!
        old.modelID = "endpoint-x"   // user's model choice must survive
        let (profiles, didUpgrade) = Profile.upgradeBuiltIns([old])
        XCTAssertTrue(didUpgrade)
        XCTAssertEqual(profiles[0].taskPrompt, Profile.cleanUp.taskPrompt)
        XCTAssertEqual(profiles[0].modelID, "endpoint-x")
    }

    func testUpgradeLeavesUserEditedBuiltInAlone() {
        var edited = Profile.cleanUp
        edited.taskPrompt = "my own instructions"
        let (profiles, didUpgrade) = Profile.upgradeBuiltIns([edited])
        XCTAssertFalse(didUpgrade)
        XCTAssertEqual(profiles[0].taskPrompt, "my own instructions")
    }

    func testUpgradeLeavesRawPromptProfileAlone() {
        var raw = Profile.cleanUp
        raw.taskPrompt = Profile.previousBuiltInTaskPrompts[Profile.cleanUpID]!.first!
        raw.rawPrompt = "custom raw prompt"
        let (profiles, didUpgrade) = Profile.upgradeBuiltIns([raw])
        XCTAssertFalse(didUpgrade)
        XCTAssertEqual(profiles[0].taskPrompt, raw.taskPrompt)
    }

    func testUpgradeIsNoopOnCurrentDefaultsAndUserProfiles() {
        let user = Profile(id: "user-1", name: "Mine", taskPrompt: "do it", guardrails: .strict)
        let (profiles, didUpgrade) = Profile.upgradeBuiltIns(Profile.builtIns + [user])
        XCTAssertFalse(didUpgrade)
        XCTAssertEqual(profiles, Profile.builtIns + [user])
    }

    func testPromptHistoryHoldsOnlyOutgoingVersions() {
        // Every history entry must differ from the current prompt, or an
        // unedited current profile would look upgradeable.
        for profile in Profile.builtIns {
            for old in Profile.previousBuiltInTaskPrompts[profile.id] ?? [] {
                XCTAssertNotEqual(old, profile.taskPrompt, "stale history for \(profile.id)")
            }
        }
    }

    func testBuiltInGuardPresets() {
        XCTAssertTrue(Profile.cleanUp.guardrails.lengthRatioGuard)
        XCTAssertFalse(Profile.summarize.guardrails.lengthRatioGuard)
        XCTAssertFalse(Profile.translateEnglish.guardrails.enforceSameLanguage)
        XCTAssertTrue(Profile.promptEngineer.guardrails.actAsAssistant)
        XCTAssertTrue(Profile.builtIns.allSatisfy { $0.isBuiltIn })
    }

    func testProfileCodableRoundTrip() throws {
        let profile = Profile(
            id: "user-1", name: "Mine", taskPrompt: "do it",
            rawPrompt: nil, modelID: "endpoint-x", guardrails: .strict, isBuiltIn: false)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: data), profile)
    }

    // MARK: - Glyphs

    func testLegacyProfileJSONDecodesWithoutGlyphFields() throws {
        // Exactly what UserDefaults holds from installs that predate icons: no
        // symbolName/tint keys. Must decode, and a legacy built-in must still
        // render its shipped glyph via the display-time fallback.
        let legacy = """
        {"id":"builtin-cleanup","name":"Clean-up","taskPrompt":"t","guardrails":\
        {"lengthRatioGuard":true,"preserveTrailingQuestions":true,\
        "enforceSameLanguage":true,"actAsAssistant":false},"isBuiltIn":true}
        """
        let profile = try JSONDecoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertNil(profile.symbolName)
        XCTAssertNil(profile.tint)
        XCTAssertEqual(profile.glyph, ProfileGlyph(symbol: "wand.and.stars", tint: .blue))
    }

    func testGlyphCodableRoundTripAndOverrides() throws {
        let profile = Profile(
            id: "user-1", name: "Mine", taskPrompt: "t",
            symbolName: "envelope", tint: .pink, guardrails: .strict)
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.glyph, ProfileGlyph(symbol: "envelope", tint: .pink))

        // A custom symbol on a built-in keeps the shipped tint until the user
        // picks their own.
        var custom = Profile.cleanUp
        custom.symbolName = "envelope"
        XCTAssertEqual(custom.glyph, ProfileGlyph(symbol: "envelope", tint: .blue))
    }

    func testGlyphMonogramFallbacks() {
        func glyph(_ name: String, symbolName: String? = nil) -> ProfileGlyph {
            Profile(id: "user-x", name: name, taskPrompt: "t",
                    symbolName: symbolName, guardrails: .strict).glyph
        }
        XCTAssertEqual(glyph("Mail").symbol, "m.circle.fill")
        XCTAssertEqual(glyph("Übersetzen").symbol, "u.circle.fill")   // diacritics fold
        XCTAssertEqual(glyph(" 42 things").symbol, "4.circle.fill")   // digits exist too
        XCTAssertEqual(glyph("🚀 Launch").symbol, "person.crop.circle.fill")
        XCTAssertEqual(glyph("").symbol, "person.crop.circle.fill")
        XCTAssertEqual(glyph("Mail", symbolName: "").symbol, "m.circle.fill") // empty ≙ unset
        XCTAssertNil(glyph("Mail").tint)
    }

    func testBuiltInGlyphsCoverAllBuiltInsDistinctly() {
        for profile in Profile.builtIns {
            XCTAssertNotNil(Profile.builtInGlyphs[profile.id], "missing glyph for \(profile.id)")
        }
        // Distinct symbols, so profiles stay tellable-apart at a glance.
        XCTAssertEqual(Set(Profile.builtInGlyphs.values.map(\.symbol)).count,
                       Profile.builtInGlyphs.count)
        // `sparkles` already means "polishing" in the pill — no built-in may claim it.
        XCTAssertFalse(Profile.builtInGlyphs.values.contains { $0.symbol == "sparkles" })
    }
}

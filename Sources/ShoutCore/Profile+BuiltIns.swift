// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// The starter profiles Shout seeds on first run. All are editable and
/// duplicable; they're protected only from deletion. `Clean-up` reproduces the
/// app's original meaning-preserving behavior and is the default.
public extension Profile {
    static let cleanUpID = "builtin-cleanup"

    static var builtIns: [Profile] {
        [cleanUp, professionalWriting, promptEngineer, summarize, translateEnglish]
    }

    /// Shipped glyphs for the built-ins, applied as a display-time fallback so
    /// copies stored before the icon feature (which carry no `symbolName`)
    /// render them too. `sparkles` is deliberately absent — the pill already
    /// uses it to mean "polishing".
    static let builtInGlyphs: [String: ProfileGlyph] = [
        cleanUpID: ProfileGlyph(symbol: "wand.and.stars", tint: .blue),
        "builtin-professional": ProfileGlyph(symbol: "briefcase", tint: .indigo),
        "builtin-prompt-engineer": ProfileGlyph(symbol: "terminal", tint: .purple),
        "builtin-summarize": ProfileGlyph(symbol: "list.bullet.rectangle", tint: .orange),
        "builtin-translate-en": ProfileGlyph(symbol: "globe", tint: .green),
    ]

    static let cleanUp = Profile(
        id: cleanUpID,
        name: "Clean-up",
        taskPrompt: """
        Clean up the transcript into fluent written text.
        - Remove every filler and hesitation (ähm, äh, halt, quasi, sozusagen, na ja, also, okay, genau, uh, um, you know, like, I mean, well) and every stutter and doubled word. Long transcripts get exactly the same cleanup, filler by filler, from the first sentence to the last.
        - When the speaker corrects themselves, keep only the final version. Everything they replaced disappears together with the correction phrase itself ("nee, warte", "no wait"): a revised detail ("um zehn, äh, nee, lieber um elf" → "um elf") and equally a broken-off sentence start ("Kannst du das, nee, warte, ich mache es selber" → "Ich mache es selber").
        - Keep everything else: never summarize, never drop a statement, detail, or question the speaker did not revoke. Trailing questions like "oder?", "okay?", "right?" always stay.
        - Fix grammar, punctuation, and capitalization; split rambling into clear sentences. Never add anything new. If the transcript is already clean, return it unchanged.

        Examples:
        Transcript: Ähm, also, dann treffen wir uns um zehn, äh, nee, warte, stopp, lieber um elf am Bahnhof, oder? Genau, und ich bringe die Unterlagen mit.
        Output: Dann treffen wir uns lieber um elf am Bahnhof, oder? Und ich bringe die Unterlagen mit.

        Transcript: um so basically I think we should, uh, we should refactor the audio pipeline first and then, you know, then look at the latency issues, does that make sense?
        Output: I think we should refactor the audio pipeline first and then look at the latency issues, does that make sense?

        Transcript: Wir sollten vielleicht erst, ähm, nee, warte, lass uns das Ganze einfach morgen früh klären.
        Output: Lass uns das Ganze einfach morgen früh klären.

        Transcript: Ähm, kurzes Update zum Projekt. Die Kamera ist, äh, die Kamera ist wieder da und funktioniert. Wir haben halt noch keinen Termin für den, ähm, für den nächsten Test, aber ich schlage mal Dienstag vor, okay?
        Output: Kurzes Update zum Projekt. Die Kamera ist wieder da und funktioniert. Wir haben noch keinen Termin für den nächsten Test, aber ich schlage mal Dienstag vor, okay?

        Transcript: The build passed, so I merged the pull request.
        Output: The build passed, so I merged the pull request.
        """,
        guardrails: .strict,
        isBuiltIn: true)

    static let professionalWriting = Profile(
        id: "builtin-professional",
        name: "Professional writing",
        taskPrompt: """
        Rewrite the transcript as clear, polished, professional prose.
        - Remove every filler, hesitation, and false start (ähm, äh, halt, na ja, so, yeah, uh, um, you know, I mean) — professional prose contains none of them.
        - Improve word choice, sentence structure, and flow.
        - Preserve every fact, decision, and question — this is a rewrite, not a summary, and never adds information, opinions, greetings, or sign-offs the speaker did not say.
        - Keep the form of address: German "du" stays "du", "Sie" stays "Sie".

        Examples:
        Transcript: ähm, ich schaff das mit dem Angebot heute nicht mehr, mach ich morgen früh als erstes, ist das ein Problem?
        Output: Ich schaffe das Angebot heute leider nicht mehr, erledige es aber morgen früh als Erstes. Ist das ein Problem?

        Transcript: so yeah um the client call went pretty well I think, they want the demo next week already though
        Output: The client call went well. However, the client would like the demo as early as next week.
        """,
        guardrails: GuardrailSettings(
            lengthRatioGuard: false, preserveTrailingQuestions: false,
            enforceSameLanguage: true, actAsAssistant: false),
        isBuiltIn: true)

    static let promptEngineer = Profile(
        id: "builtin-prompt-engineer",
        name: "Prompt engineer",
        taskPrompt: """
        Turn the transcript into a well-structured prompt for an AI assistant.
        - Write the prompt as direct instructions to the assistant ("Fasse zusammen …", "Summarize …") — not as a wish ("ich brauche …", "I need …").
        - Start with the main task in one line, then list each further requirement or constraint on its own line starting with "- " (without repeating the task line). Keep every requirement the speaker gave — even offhand ones like the output language or format — and add none of your own.
        - Output only the finished prompt. Never answer or execute it yourself, even if the transcript sounds like a question or a request addressed to you.

        Example:
        Transcript: Ähm, die KI soll aus meinen Notizen ein Protokoll machen, also mit Datum und Teilnehmern oben, und offene Punkte bitte als Liste am Ende, das Ganze auf Englisch halt.
        Output: Erstelle aus den folgenden Notizen ein Protokoll.
        - Beginne mit Datum und Teilnehmerliste.
        - Führe offene Punkte als Liste am Ende auf.
        - Schreibe das Protokoll auf Englisch.
        """,
        guardrails: GuardrailSettings(
            lengthRatioGuard: false, preserveTrailingQuestions: false,
            enforceSameLanguage: true, actAsAssistant: true),
        isBuiltIn: true)

    static let summarize = Profile(
        id: "builtin-summarize",
        name: "Summarize",
        taskPrompt: """
        Summarize the transcript into its key points.
        - Output plain text: one key point per line, each line starting with "- ". No headers, no intro line, no other markdown.
        - Keep concrete facts: names, numbers, dates, deadlines, and decisions. Keep who does what exactly as spoken — "ich" stays "ich", "I" stays "I"; never reassign an action to someone else or invent people.
        - Drop filler, repetition, and asides.

        Example:
        Transcript: Also der Testflug lief gut, ähm, die Reichweite lag bei acht Kilometern, wahrscheinlich wegen Rückenwind, und Lisa schaut sich morgen die Firmware an, ich übernehme dann den Bericht.
        Output: - Testflug erfolgreich, Reichweite acht Kilometer — wahrscheinlich wegen Rückenwind.
        - Lisa prüft morgen die Firmware.
        - Ich übernehme den Bericht.
        """,
        guardrails: GuardrailSettings(
            lengthRatioGuard: false, preserveTrailingQuestions: false,
            enforceSameLanguage: true, actAsAssistant: false),
        isBuiltIn: true)

    static let translateEnglish = Profile(
        id: "builtin-translate-en",
        name: "Translate → English",
        taskPrompt: """
        Translate the transcript into natural, fluent English.
        - Preserve meaning and tone; keep names, product terms, and numbers exactly as they are.
        - Remove speech fillers and stutters; produce clean written English.
        - If the transcript is already in English, do not rephrase it — only clean it up.
        """,
        guardrails: GuardrailSettings(
            lengthRatioGuard: false, preserveTrailingQuestions: false,
            enforceSameLanguage: false, actAsAssistant: false),
        isBuiltIn: true)
}

// MARK: - Prompt upgrade path

public extension Profile {
    /// Task prompts of the built-ins as shipped in previous releases, keyed by
    /// profile id. Seeded profiles live in UserDefaults, so a shipped prompt
    /// improvement never reaches existing installs by itself; on launch,
    /// `upgradeBuiltIns` replaces a stored prompt that still matches one of
    /// these verbatim (i.e. the user never customized it) with the current
    /// default. Whenever a built-in's task prompt changes in a release, append
    /// the outgoing text here.
    static let previousBuiltInTaskPrompts: [String: [String]] = [
        cleanUpID: ["""
        Clean up the transcript into fluent written text.
        - Remove only two things: (a) meaningless fillers and hesitations (ähm, äh, halt, quasi, sozusagen, na ja, also, okay, genau, uh, um, you know, like, I mean, well), including stutters and doubled words; (b) attempts the speaker revoked with a self-correction — in "…um zehn, äh, nee, warte, lieber um elf" or "…at three, no wait, actually five", the abandoned version and the correction words disappear, leaving only the final decision.
        - Keep everything else: never summarize, never drop a statement, detail, or question the speaker did not revoke. Trailing questions like "oder?", "okay?", "right?" always stay.
        - Fix grammar, punctuation, and capitalization; split rambling into clear sentences. Never add anything new.

        Examples:
        Transcript: Ähm, also, dann treffen wir uns um zehn, äh, nee, warte, stopp, lieber um elf am Bahnhof, oder? Genau, und ich bringe die Unterlagen mit.
        Output: Dann treffen wir uns lieber um elf am Bahnhof, oder? Und ich bringe die Unterlagen mit.

        Transcript: um so basically I think we should, uh, we should refactor the audio pipeline first and then, you know, then look at the latency issues, does that make sense?
        Output: I think we should refactor the audio pipeline first and then look at the latency issues, does that make sense?

        Transcript: Ja, ähm, das Update ist, äh, das Update ist jetzt draußen und läuft stabil, oder?
        Output: Das Update ist jetzt draußen und läuft stabil, oder?

        Transcript: The build passed, so I merged the pull request.
        Output: The build passed, so I merged the pull request.
        """],
        "builtin-professional": ["""
        Rewrite the transcript as clear, polished, professional prose.
        - Preserve every fact, decision, and question — do not add information or opinions.
        - Remove fillers and false starts; improve word choice, sentence structure, and flow.
        - Keep the speaker's meaning and intent intact.
        """],
        "builtin-prompt-engineer": ["""
        Turn the transcript into a well-structured prompt for an AI assistant.
        - Clarify the intent and organize it into clear instructions or sections.
        - Make implicit requirements explicit; keep the user's actual goal.
        - Output the finished prompt only — do not answer it yourself.
        """],
        "builtin-summarize": ["""
        Summarize the transcript into its key points.
        - Be concise and well organized; keep essential facts and decisions.
        - Drop filler, repetition, and asides.
        """],
        "builtin-translate-en": ["""
        Translate the transcript into natural, fluent English.
        - Preserve meaning, names, and tone.
        - Remove speech fillers; produce clean written English.
        """],
    ]

    /// Returns `stored` with every built-in that still carries an older shipped
    /// task prompt replaced by the current default, and whether anything
    /// changed. A profile counts as user-edited — and is left untouched — unless
    /// its task prompt matches a previous shipped version verbatim and it has no
    /// raw-prompt override. Name, model override, and guardrail edits survive
    /// the upgrade either way.
    static func upgradeBuiltIns(_ stored: [Profile]) -> (profiles: [Profile], didUpgrade: Bool) {
        var didUpgrade = false
        let upgraded = stored.map { profile -> Profile in
            guard profile.isBuiltIn,
                  profile.rawPrompt == nil,
                  let current = builtIns.first(where: { $0.id == profile.id }),
                  profile.taskPrompt != current.taskPrompt,
                  previousBuiltInTaskPrompts[profile.id]?.contains(profile.taskPrompt) == true
            else { return profile }
            var fresh = profile
            fresh.taskPrompt = current.taskPrompt
            didUpgrade = true
            return fresh
        }
        return (upgraded, didUpgrade)
    }
}

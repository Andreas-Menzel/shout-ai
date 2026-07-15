// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import ShoutCore

// Headless test harness for the Shout pipeline.
//
//   shout-cli status
//   shout-cli transcribe <audio-file> [auto|de|en]
//   shout-cli rewrite "<text>" [de|en]
//   shout-cli pipeline <audio-file> [auto|de|en]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func modelURL() -> URL {
    ShoutPaths.modelsDir.appendingPathComponent(WhisperModelSpec.largeV3Turbo.fileName)
}

func modelPath() -> String { modelURL().path }

func loadTranscriber() async throws -> WhisperTranscriber {
    let transcriber = WhisperTranscriber(modelURL: modelURL())
    let started = Date()
    try await transcriber.prepare()
    print("model-load: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    return transcriber
}

func languageMode(_ raw: String?) -> LanguageMode {
    LanguageMode(rawValue: raw ?? "auto") ?? .auto
}

func runTranscribe(file: String, lang: LanguageMode) async throws -> TranscriptionResult {
    let samples = try AudioFileLoader.loadSamples16k(url: URL(fileURLWithPath: file))
    print("audio: \(String(format: "%.1f", Double(samples.count) / AudioRecorder.targetSampleRate))s")
    let transcriber = try await loadTranscriber()
    let started = Date()
    let result = try await transcriber.transcribe(samples: samples, language: lang, glossary: [])
    print("transcribe: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    print("language: \(result.languageCode)")
    print("text: \(result.text)")
    return result
}

func builtInProfile(_ name: String?) -> Profile {
    switch name?.lowercased() {
    case "professional": return .professionalWriting
    case "prompt": return .promptEngineer
    case "summarize": return .summarize
    case "translate": return .translateEnglish
    default: return .cleanUp
    }
}

func runRewrite(text: String, langCode: String?, profile: Profile = .cleanUp, glossary: [String] = []) async throws -> String {
    let rewriter = AppleFoundationRewriter()
    guard rewriter.isAvailable else {
        fail("rewrite unavailable: \(rewriter.availabilityDescription)")
    }
    let started = Date()
    let cleaned = try await rewriter.rewrite(profile: profile, transcript: text, languageCode: langCode, glossary: glossary)
    print("profile: \(profile.name)")
    print("rewrite: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    print("cleaned: \(cleaned)")
    return cleaned
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: shout-cli status | transcribe <file> [lang] | rewrite <text> [lang] [profile] | rewrite-endpoint <baseURL> <model> <text> [lang] | voice-switch <text> [trigger] | pipeline <file> [lang]")
}

switch command {
case "status":
    let exists = FileManager.default.fileExists(atPath: modelPath())
    print("model: \(exists ? "installed" : "missing") at \(modelPath())")
    let rewriter = AppleFoundationRewriter()
    print("apple-intelligence: \(rewriter.availabilityDescription)")

case "transcribe":
    guard arguments.count >= 2 else { fail("usage: shout-cli transcribe <file> [auto|de|en]") }
    _ = try await runTranscribe(file: arguments[1], lang: languageMode(arguments.count > 2 ? arguments[2] : nil))

case "rewrite":
    guard arguments.count >= 2 else { fail("usage: shout-cli rewrite <text> [de|en] [cleanup|professional|prompt|summarize|translate] [term1,term2]") }
    _ = try await runRewrite(
        text: arguments[1],
        langCode: arguments.count > 2 ? arguments[2] : nil,
        profile: builtInProfile(arguments.count > 3 ? arguments[3] : nil),
        glossary: arguments.count > 4 ? arguments[4].split(separator: ",").map(String.init) : [])

case "pipeline":
    guard arguments.count >= 2 else { fail("usage: shout-cli pipeline <file> [auto|de|en]") }
    let result = try await runTranscribe(file: arguments[1], lang: languageMode(arguments.count > 2 ? arguments[2] : nil))
    guard !result.text.isEmpty else { fail("empty transcript") }
    _ = try await runRewrite(text: result.text, langCode: result.languageCode)

case "rewrite-endpoint":
    guard arguments.count >= 4 else { fail("usage: shout-cli rewrite-endpoint <baseURL> <model> <text> [de|en]") }
    guard let url = URL(string: arguments[1]) else { fail("invalid base URL: \(arguments[1])") }
    let endpoint = EndpointRewriter(config: EndpointConfig(baseURL: url, model: arguments[2]))
    let startedEndpoint = Date()
    let cleanedEndpoint = try await endpoint.rewrite(
        profile: .cleanUp,
        transcript: arguments[3],
        languageCode: arguments.count > 4 ? arguments[4] : nil,
        glossary: [])
    print("rewrite: \(String(format: "%.2f", Date().timeIntervalSince(startedEndpoint)))s")
    print("cleaned: \(cleanedEndpoint)")

case "voice-switch":
    guard arguments.count >= 2 else { fail("usage: shout-cli voice-switch <transcript> [trigger]") }
    let trigger = arguments.count > 2 ? arguments[2] : "use profile"
    let list = Profile.builtIns.map { (id: $0.id, name: $0.name) }
    if let match = VoiceCommand.parse(transcript: arguments[1], trigger: trigger, profiles: list),
       let profile = Profile.builtIns.first(where: { $0.id == match.profileID }) {
        print("matched-profile: \(profile.name)")
        print("remainder: \(match.remainder.isEmpty ? "(pure switch — nothing to insert)" : match.remainder)")
        if !match.remainder.isEmpty {
            let rewriter = AppleFoundationRewriter()
            guard rewriter.isAvailable else { fail("rewrite unavailable: \(rewriter.availabilityDescription)") }
            let cleaned = try await rewriter.rewrite(profile: profile, transcript: match.remainder, languageCode: nil, glossary: [])
            print("cleaned: \(cleaned)")
        }
    } else {
        print("no command detected")
    }

case "diagnose-profile":
    guard arguments.count >= 3 else { fail("usage: shout-cli diagnose-profile <taskPrompt> <text> [lang]") }
    let diagProfile = Profile(id: "diag", name: "Diag", taskPrompt: arguments[1], guardrails: .strict)
    let diagText = arguments[2]
    let diagLang = arguments.count > 3 ? arguments[3] : nil
    let diagEngine = AppleFoundationRewriter()
    guard diagEngine.isAvailable else { fail("rewrite unavailable: \(diagEngine.availabilityDescription)") }
    let diagPrompt = diagProfile.buildPrompt(transcript: diagText, languageCode: diagLang, glossary: [])
    let diagRaw = try await diagEngine.complete(system: diagPrompt.system, user: diagPrompt.user)
    let diagFinal = try await diagEngine.rewrite(profile: diagProfile, transcript: diagText, languageCode: diagLang, glossary: [])
    print("=== model raw output ===\n\(diagRaw)")
    print("\n=== after postprocess + strict guards ===\n\(diagFinal)")
    print("\n=== guard reverted to raw input: \(diagFinal == diagText) ===")

case "fnwatch":
    let seconds = arguments.count > 1 ? (Double(arguments[1]) ?? 20) : 20
    FnWatch.run(seconds: seconds)

default:
    fail("unknown command: \(command)")
}

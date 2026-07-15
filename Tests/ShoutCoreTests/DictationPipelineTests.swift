// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

private final class FakeTranscriber: TranscriptionEngine, @unchecked Sendable {
    var text: String
    var languageCode: String
    private(set) var prepareCalls = 0
    init(text: String, languageCode: String = "en") { self.text = text; self.languageCode = languageCode }
    var isReady: Bool { true }
    func prepare() async throws { prepareCalls += 1 }
    func transcribe(samples: [Float], language: LanguageMode, glossary: [String]) async throws -> TranscriptionResult {
        TranscriptionResult(text: text, languageCode: languageCode)
    }
}

private final class FakeRewriter: RewriteEngine, @unchecked Sendable {
    enum Behavior { case returns(String), throwsError, unavailable }
    var behavior: Behavior
    /// Overridable so tests can prove the pipeline budgets by ENGINE deadline.
    var deadline: TimeInterval = Tuning.rewriteTimeout
    /// Simulated generation latency before the reply.
    var delay: TimeInterval = 0
    private(set) var completeCalls = 0
    init(_ behavior: Behavior) { self.behavior = behavior }
    var availability: EngineAvailability {
        if case .unavailable = behavior { return .unavailable("off") }
        return .available
    }
    var maxInputCharacters: Int { .max }
    var rewriteDeadline: TimeInterval { deadline }
    func prewarm(instructions: String) {}
    func complete(system: String, user: String) async throws -> String {
        completeCalls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        switch behavior {
        case .returns(let s): return s
        case .throwsError, .unavailable: throw ShoutError.rewriteUnavailable
        }
    }
}

@MainActor
final class DictationPipelineTests: XCTestCase {

    /// A resolver that never strips and always uses the given engine + Clean-up.
    private func resolver(_ rewriter: FakeRewriter) -> (String) -> RewriteResolution {
        { RewriteResolution(text: $0, step: RewriteStep(engine: rewriter, profile: .cleanUp)) }
    }
    private func noRewrite(_ text: String) -> RewriteResolution { RewriteResolution(text: text, step: nil) }

    func testEmptyTranscriptReturnsNil() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: ""))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 4,
            resolve: resolver(FakeRewriter(.returns("x"))))
        XCTAssertNil(outcome)
    }

    func testRewriteBudgetComesFromEngineDeadline() async throws {
        // An engine that overruns ITS OWN deadline falls back to raw…
        let raw = "one two three four five six"
        let slow = FakeRewriter(.returns("One two three four five six."))
        slow.deadline = 0.05
        slow.delay = 0.5
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: raw))
        let timedOut = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 4,
            resolve: resolver(slow))
        XCTAssertEqual(timedOut?.final, raw)
        XCTAssertEqual(timedOut?.polishFellBack, true)

        // …while the same latency inside a generous deadline (an endpoint
        // model that streams slowly but steadily) is given time to finish.
        let slowButAllowed = FakeRewriter(.returns("One two three four five six."))
        slowButAllowed.deadline = 5
        slowButAllowed.delay = 0.2
        let finished = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 4,
            resolve: resolver(slowButAllowed))
        XCTAssertEqual(finished?.final, "One two three four five six.")
        XCTAssertEqual(finished?.rewritten, true)
    }

    func testSkipsRewriteBelowMinWords() async throws {
        let rewriter = FakeRewriter(.returns("SHOULD NOT RUN"))
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "hello there"))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 4,
            resolve: resolver(rewriter))
        XCTAssertEqual(rewriter.completeCalls, 0)
        XCTAssertEqual(outcome?.rewritten, false)
        XCTAssertEqual(outcome?.polishFellBack, false)
        XCTAssertEqual(outcome?.final, "hello there")
    }

    func testUsesRewriteWhenEligible() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "one two three four five"))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 4,
            resolve: resolver(FakeRewriter(.returns("One two three four five."))))
        XCTAssertEqual(outcome?.rewritten, true)
        XCTAssertEqual(outcome?.polishFellBack, false)
        XCTAssertEqual(outcome?.final, "One two three four five.")
    }

    func testFallsBackToRawWhenRewriteThrows() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "one two three four five"))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 4,
            resolve: resolver(FakeRewriter(.throwsError)))
        XCTAssertEqual(outcome?.rewritten, false)
        XCTAssertEqual(outcome?.polishFellBack, true)
        XCTAssertEqual(outcome?.final, "one two three four five")
    }

    func testDisabledRewriteDoesNotFlagRaw() async throws {
        let rewriter = FakeRewriter(.returns("x"))
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "one two three four five"))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: false, minWords: 4,
            resolve: resolver(rewriter))
        XCTAssertEqual(rewriter.completeCalls, 0)
        XCTAssertEqual(outcome?.rewritten, false)
        XCTAssertEqual(outcome?.polishFellBack, false)
    }

    func testNilRewriteStepSkipsPolish() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "one two three four five"))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 4,
            resolve: noRewrite)
        XCTAssertEqual(outcome?.rewritten, false)
        XCTAssertEqual(outcome?.polishFellBack, false)
        XCTAssertEqual(outcome?.final, "one two three four five")
    }

    func testResolverCanStripAndRedirect() async throws {
        // Simulates a voice command: strip a leading command, process the remainder.
        let rewriter = FakeRewriter(.returns("Summary."))
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "use profile summarize the update is out"))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 1,
            resolve: { _ in RewriteResolution(text: "the update is out", step: RewriteStep(engine: rewriter, profile: .summarize)) })
        XCTAssertEqual(rewriter.completeCalls, 1)
        XCTAssertEqual(outcome?.raw, "use profile summarize the update is out")   // raw preserved
        XCTAssertEqual(outcome?.final, "Summary.")                                // remainder processed
    }

    func testResolverFailedShortInsertsNothing() async throws {
        // A botched voice command ("use profile xyzzy") resolves to empty text:
        // the pipeline must return a real outcome with an empty final (so the
        // caller can show its failure notice), not nil (= "didn't catch anything").
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "use profile xyzzy"))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: [], rewriteEnabled: true, minWords: 4,
            resolve: { _ in RewriteResolution(text: "", step: nil) })
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.final, "")
        XCTAssertEqual(outcome?.raw, "use profile xyzzy")
    }

    func testGlossaryNormalizationApplied() async throws {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber(text: "we use http server"))
        let outcome = try await pipeline.run(
            samples: [], language: .auto, glossary: ["HTTPServer"], rewriteEnabled: true, minWords: 1,
            resolve: resolver(FakeRewriter(.unavailable)))
        // Rewrite unavailable → raw path, but deterministic normalization still
        // fixes the glossary spelling.
        XCTAssertEqual(outcome?.final, "we use HTTPServer")
    }
}

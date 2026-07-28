// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

/// Intercepts URLSession traffic so the endpoint engine's real request/response
/// path can be exercised without a live server.
private final class StubURLProtocol: URLProtocol {
    struct Stub { let status: Int; let body: Data }
    // Test-stub state: set before a request and read after the awaited round-trip
    // completes, so access is serialised across the URLSession protocol queue.
    nonisolated(unsafe) static var stub: Stub?
    nonisolated(unsafe) static var lastURL: URL?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// URLSession hands the body to a URLProtocol as a stream, never httpBody.
    private static func drainBody(of request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        Self.lastURL = request.url
        Self.lastRequestBody = Self.drainBody(of: request)
        guard let stub = Self.stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class EndpointRewriterTests: XCTestCase {
    private let config = EndpointConfig(baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen3:4b")

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.stub = nil
        StubURLProtocol.lastURL = nil
        StubURLProtocol.lastRequestBody = nil
        super.tearDown()
    }

    // MARK: - Wire format

    func testRequestBodyShape() throws {
        let body = EndpointRewriter.requestBody(model: "m", system: "sys", user: "usr")
        XCTAssertEqual(body.model, "m")
        XCTAssertEqual(body.messages, [.init(role: "system", content: "sys"), .init(role: "user", content: "usr")])
        XCTAssertEqual(body.temperature, 0)
        XCTAssertTrue(body.stream)   // streamed so chunks reset the idle timeout
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(body), encoding: .utf8))
        XCTAssertTrue(json.contains("\"role\":\"system\""))
        XCTAssertTrue(json.contains("\"role\":\"user\""))
    }

    func testRequestBodySendsGenerousMaxTokens() throws {
        // The explicit cap overrides a server-side per-model response limit,
        // which a reasoning model can otherwise exhaust before any answer text.
        let body = EndpointRewriter.requestBody(model: "m", system: "s", user: "u")
        XCTAssertEqual(body.maxTokens, Tuning.endpointMaxTokens)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(body), encoding: .utf8))
        XCTAssertTrue(json.contains("\"max_tokens\":\(Tuning.endpointMaxTokens)"))
    }

    func testRequestBodyOmitsReasoningEffortUnlessSet() throws {
        // Sent only on explicit user choice; strict servers must never see a
        // surprise field.
        let body = EndpointRewriter.requestBody(model: "m", system: "s", user: "u")
        XCTAssertNil(body.reasoningEffort)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(body), encoding: .utf8))
        XCTAssertFalse(json.contains("reasoning_effort"))
    }

    func testRequestBodyEncodesChosenReasoningEffort() throws {
        // "Off" goes on the wire as OpenAI's/Ollama's "none".
        let off = EndpointRewriter.requestBody(model: "m", reasoningEffort: .off, system: "s", user: "u")
        let offJSON = try XCTUnwrap(String(data: JSONEncoder().encode(off), encoding: .utf8))
        XCTAssertTrue(offJSON.contains("\"reasoning_effort\":\"none\""))
        let high = EndpointRewriter.requestBody(model: "m", reasoningEffort: .high, system: "s", user: "u")
        let highJSON = try XCTUnwrap(String(data: JSONEncoder().encode(high), encoding: .utf8))
        XCTAssertTrue(highJSON.contains("\"reasoning_effort\":\"high\""))
    }

    func testEndpointConfigDecodesLegacyJSONWithoutReasoningEffort() throws {
        // Persisted configs from before the reasoning setting must keep decoding.
        let legacy = Data(#"{"baseURL":"http://localhost:11434/v1","model":"qwen3:4b"}"#.utf8)
        var decoded = try JSONDecoder().decode(EndpointConfig.self, from: legacy)
        XCTAssertNil(decoded.reasoningEffort)
        // And a chosen value survives the registry's encode/decode round-trip.
        decoded.reasoningEffort = .off
        let redecoded = try JSONDecoder().decode(EndpointConfig.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(redecoded.reasoningEffort, .off)
    }

    func testParseContentValidTrims() {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"  Hello there.  "}}]}"#.utf8)
        XCTAssertEqual(EndpointRewriter.parseContent(data), "Hello there.")
    }

    func testParseContentRejectsEmptyOrMalformed() {
        XCTAssertNil(EndpointRewriter.parseContent(Data(#"{"choices":[]}"#.utf8)))
        XCTAssertNil(EndpointRewriter.parseContent(Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8)))
        XCTAssertNil(EndpointRewriter.parseContent(Data(#"{"choices":[{"message":{}}]}"#.utf8)))
        XCTAssertNil(EndpointRewriter.parseContent(Data("<html>error</html>".utf8)))
    }

    func testParseContentStripsInlineThinkBlocks() {
        // Multiline chain-of-thought before the answer (the \n stays a JSON
        // escape inside the raw string, decoding to a real newline).
        let leading = Data(#"{"choices":[{"message":{"content":"<think>User wants a cleanup.\nKeep it short.</think>Hello there."}}]}"#.utf8)
        XCTAssertEqual(EndpointRewriter.parseContent(leading), "Hello there.")
        // An opening tag the response cap cut off before its close.
        let unterminated = Data(#"{"choices":[{"message":{"content":"Hello there.<think>and now I wonder whether"}}]}"#.utf8)
        XCTAssertEqual(EndpointRewriter.parseContent(unterminated), "Hello there.")
    }

    func testParseContentTreatsThinkOnlyReplyAsEmpty() {
        // A cap consumed entirely by reasoning leaves no answer at all.
        XCTAssertNil(EndpointRewriter.parseContent(
            Data(#"{"choices":[{"message":{"content":"<think>pondering, done</think>"}}]}"#.utf8)))
        XCTAssertNil(EndpointRewriter.parseContent(
            Data(#"{"choices":[{"message":{"content":"<think>pondering, never finished"}}]}"#.utf8)))
    }

    // MARK: - Stream assembly

    func testStreamAssemblerJoinsDeltasAndStopsAtDone() {
        var assembler = EndpointRewriter.StreamAssembler()
        XCTAssertFalse(assembler.consume(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertFalse(assembler.consume(#"data: {"choices":[{"delta":{"content":"Hello"}}]}"#))
        XCTAssertFalse(assembler.consume(#"data: {"choices":[{"delta":{"content":" there."}}]}"#))
        XCTAssertFalse(assembler.consume(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#))
        XCTAssertTrue(assembler.consume("data: [DONE]"))
        XCTAssertEqual(assembler.content, "Hello there.")
    }

    func testStreamAssemblerIgnoresReasoningDeltas() {
        // Ollama/LM Studio stream thinking as reasoning/reasoning_content
        // deltas; only content may reach the document.
        var assembler = EndpointRewriter.StreamAssembler()
        _ = assembler.consume(#"data: {"choices":[{"delta":{"reasoning":"pondering the plan"}}]}"#)
        _ = assembler.consume(#"data: {"choices":[{"delta":{"reasoning_content":"more pondering"}}]}"#)
        _ = assembler.consume(#"data: {"choices":[{"delta":{"content":"Answer."}}]}"#)
        XCTAssertEqual(assembler.content, "Answer.")
    }

    func testStreamAssemblerStripsThinkSplitAcrossChunks() {
        // Inline thinking arrives split over chunk boundaries; the strip runs
        // on the assembled text, so a tag no single chunk contains still goes.
        var assembler = EndpointRewriter.StreamAssembler()
        _ = assembler.consume(#"data: {"choices":[{"delta":{"content":"<th"}}]}"#)
        _ = assembler.consume(#"data: {"choices":[{"delta":{"content":"ink>hmm</think>Done."}}]}"#)
        XCTAssertEqual(assembler.content, "Done.")
    }

    func testStreamAssemblerEmptyDoneOnlyOrThinkOnlyIsNil() {
        let empty = EndpointRewriter.StreamAssembler()
        XCTAssertNil(empty.content)
        var doneOnly = EndpointRewriter.StreamAssembler()
        XCTAssertTrue(doneOnly.consume("data: [DONE]"))
        XCTAssertNil(doneOnly.content)
        var thinkOnly = EndpointRewriter.StreamAssembler()
        _ = thinkOnly.consume(#"data: {"choices":[{"delta":{"content":"<think>never finished"}}]}"#)
        XCTAssertNil(thinkOnly.content)
    }

    func testStreamAssemblerFallsBackToPlainJSONBody() {
        // A server that ignores stream:true replies with one JSON body.
        var assembler = EndpointRewriter.StreamAssembler()
        _ = assembler.consume(#"{"choices":[{"message":{"content":"Hello there."}}]}"#)
        XCTAssertEqual(assembler.content, "Hello there.")
    }

    // MARK: - rewrite() round-trip

    func testRewriteReturnsCleanedAndHitsCorrectURL() async throws {
        StubURLProtocol.stub = .init(
            status: 200,
            body: Data(#"{"choices":[{"message":{"content":"I think we should refactor first, does that make sense?"}}]}"#.utf8))
        let engine = EndpointRewriter(config: config, session: stubbedSession())
        let out = try await engine.rewrite(
            profile: .cleanUp,
            transcript: "um so basically I think we should, uh, refactor first, does that make sense?",
            languageCode: "en", glossary: [])
        XCTAssertEqual(out, "I think we should refactor first, does that make sense?")
        XCTAssertEqual(StubURLProtocol.lastURL?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testRewriteAssemblesStreamedSSEResponse() async throws {
        // The real wire shape: SSE chunks, an inline think block, then [DONE].
        let sse = """
        data: {"choices":[{"delta":{"content":"<think>plan the cleanup</think>"}}]}
        data: {"choices":[{"delta":{"content":"I think we should refactor first, "}}]}
        data: {"choices":[{"delta":{"content":"does that make sense?"}}]}
        data: [DONE]
        """
        StubURLProtocol.stub = .init(status: 200, body: Data(sse.utf8))
        let engine = EndpointRewriter(config: config, session: stubbedSession())
        let out = try await engine.rewrite(
            profile: .cleanUp,
            transcript: "um so basically I think we should, uh, refactor first, does that make sense?",
            languageCode: "en", glossary: [])
        XCTAssertEqual(out, "I think we should refactor first, does that make sense?")
    }

    func testEndpointDeadlineOutlivesOnDeviceCeiling() {
        // The pipeline budget comes from the engine: endpoints stream, so they
        // may run far past the on-device ceiling before the raw fallback.
        XCTAssertEqual(EndpointRewriter(config: config).rewriteDeadline, Tuning.endpointRewriteTimeout)
        XCTAssertGreaterThan(Tuning.endpointRewriteTimeout, Tuning.rewriteTimeout)
    }

    func testRewriteRevertsToRawWhenQualityGuardTrips() async throws {
        // Reply drops the speaker's trailing question → isTrustworthy fails → raw kept.
        StubURLProtocol.stub = .init(
            status: 200,
            body: Data(#"{"choices":[{"message":{"content":"We ship tomorrow."}}]}"#.utf8))
        let engine = EndpointRewriter(config: config, session: stubbedSession())
        let raw = "we ship tomorrow, oder?"
        let out = try await engine.rewrite(profile: .cleanUp, transcript: raw, languageCode: "de", glossary: [])
        XCTAssertEqual(out, raw)
    }

    func testRewriteThrowsOnBadStatus() async {
        StubURLProtocol.stub = .init(status: 500, body: Data("server error".utf8))
        let engine = EndpointRewriter(config: config, session: stubbedSession())
        await assertThrows(engine, expected: .endpointBadStatus(500))
    }

    func testCompleteSendsConfiguredReasoningEffortAndMaxTokensOnTheWire() async throws {
        StubURLProtocol.stub = .init(
            status: 200,
            body: Data(#"{"choices":[{"message":{"content":"hi"}}]}"#.utf8))
        var config = self.config
        config.reasoningEffort = .low
        let engine = EndpointRewriter(config: config, session: stubbedSession())
        _ = try await engine.complete(system: "s", user: "u")
        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("\"reasoning_effort\":\"low\""))
        XCTAssertTrue(body.contains("\"max_tokens\":\(Tuning.endpointMaxTokens)"))
    }

    func testRewriteThrowsEmptyWhenReplyIsThinkOnly() async {
        // The stripped-to-nothing reply must surface as endpointEmptyResponse,
        // which is what triggers the caller's raw-transcript fallback.
        StubURLProtocol.stub = .init(
            status: 200,
            body: Data(#"{"choices":[{"message":{"content":"<think>hit the token cap while reasoning"}}]}"#.utf8))
        let engine = EndpointRewriter(config: config, session: stubbedSession())
        await assertThrows(engine, expected: .endpointEmptyResponse)
    }

    func testRewriteThrowsOnMalformedBody() async {
        StubURLProtocol.stub = .init(status: 200, body: Data("<html>nope</html>".utf8))
        let engine = EndpointRewriter(config: config, session: stubbedSession())
        await assertThrows(engine, expected: .endpointEmptyResponse)
    }

    func testCompleteThrowsWhenNotConfigured() async {
        let unconfigured = EndpointConfig(baseURL: URL(string: "http://localhost:11434/v1")!, model: "   ")
        let engine = EndpointRewriter(config: unconfigured, session: stubbedSession())
        do {
            _ = try await engine.complete(system: "s", user: "u")
            XCTFail("expected endpointNotConfigured")
        } catch let error as ShoutError {
            XCTAssertEqual(error, .endpointNotConfigured)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRewriteThrowsWhenUnavailable() async {
        // The shared rewrite() guards availability before calling complete().
        let unconfigured = EndpointConfig(baseURL: URL(string: "http://localhost:11434/v1")!, model: "   ")
        let engine = EndpointRewriter(config: unconfigured, session: stubbedSession())
        await assertThrows(engine, expected: .rewriteUnavailable)
    }

    // MARK: - availability & privacy classification

    func testAvailabilityReflectsConfiguration() {
        XCTAssertTrue(EndpointRewriter(config: config).isAvailable)
        let empty = EndpointConfig(baseURL: URL(string: "http://localhost/v1")!, model: "")
        XCTAssertFalse(EndpointRewriter(config: empty).isAvailable)
    }

    func testLoopbackClassifiedLocalRemoteNot() {
        func loopback(_ url: String) -> Bool {
            EndpointConfig(baseURL: URL(string: url)!, model: "m").isLoopback
        }
        XCTAssertTrue(loopback("http://localhost:11434/v1"))
        XCTAssertTrue(loopback("http://127.0.0.1:1234/v1"))
        XCTAssertFalse(loopback("http://192.168.1.9:11434/v1"))
        XCTAssertFalse(loopback("https://api.example.com/v1"))

        // The whole of 127.0.0.0/8 is this Mac, not just .0.1 — warning that a
        // transcript "leaves your Mac" would be wrong for any of these.
        XCTAssertTrue(loopback("http://127.0.0.2:11434/v1"))
        XCTAssertTrue(loopback("http://127.1.2.3:11434/v1"))
        XCTAssertTrue(loopback("http://127.255.255.255/v1"))
        XCTAssertTrue(loopback("http://[::1]:11434/v1"))

        // Near-misses must not be mistaken for loopback: over-warning is the safe
        // direction, under-warning is a privacy claim we'd be breaking.
        XCTAssertFalse(loopback("http://128.0.0.1/v1"))
        XCTAssertFalse(loopback("http://27.0.0.1/v1"))
        XCTAssertFalse(loopback("http://1270.0.0.1/v1"))
        XCTAssertFalse(loopback("http://127.0.0.999/v1"))
        XCTAssertFalse(loopback("http://127.0.0.1.evil.com/v1"))
        XCTAssertFalse(loopback("https://localhost.evil.com/v1"))
    }

    func testInsecureRemoteClassification() {
        // Only remote http is insecure: loopback http and https never are.
        XCTAssertTrue(EndpointConfig(baseURL: URL(string: "http://192.168.1.9:11434/v1")!, model: "m").isInsecureRemote)
        XCTAssertTrue(EndpointConfig(baseURL: URL(string: "http://api.example.com/v1")!, model: "m").isInsecureRemote)
        XCTAssertFalse(EndpointConfig(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m").isInsecureRemote)
        XCTAssertFalse(EndpointConfig(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, model: "m").isInsecureRemote)
        XCTAssertFalse(EndpointConfig(baseURL: URL(string: "https://api.example.com/v1")!, model: "m").isInsecureRemote)
    }

    func testInsecureRemoteUnavailableUntilAllowed() {
        let remoteHTTP = EndpointConfig(baseURL: URL(string: "http://api.example.com/v1")!, model: "m")
        // Blocked when the clear-text opt-in is off…
        XCTAssertFalse(EndpointRewriter(config: remoteHTTP, allowInsecureHTTP: false).isAvailable)
        // …available once the user opts in.
        XCTAssertTrue(EndpointRewriter(config: remoteHTTP, allowInsecureHTTP: true).isAvailable)
        // Loopback http and remote https are unaffected by the opt-in.
        let loopback = EndpointConfig(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m")
        let remoteHTTPS = EndpointConfig(baseURL: URL(string: "https://api.example.com/v1")!, model: "m")
        XCTAssertTrue(EndpointRewriter(config: loopback, allowInsecureHTTP: false).isAvailable)
        XCTAssertTrue(EndpointRewriter(config: remoteHTTPS, allowInsecureHTTP: false).isAvailable)
    }

    func testCompleteThrowsOnBlockedInsecureRemote() async {
        let remoteHTTP = EndpointConfig(baseURL: URL(string: "http://api.example.com/v1")!, model: "m")
        let engine = EndpointRewriter(config: remoteHTTP, allowInsecureHTTP: false, session: stubbedSession())
        do {
            _ = try await engine.complete(system: "s", user: "u")
            XCTFail("expected an insecure-HTTP error before any request")
        } catch {
            XCTAssertEqual(error as? ShoutError, .endpointInsecureHTTP)
        }
    }

    func testModelEntryCodableRoundTrip() throws {
        // This is what the registry persists to UserDefaults, so it must survive
        // an encode/decode cleanly — including the endpoint associated value.
        let endpoint = ModelEntry(
            id: "endpoint-x", displayName: "My Server",
            kind: .endpoint(EndpointConfig(baseURL: URL(string: "https://api.example.com/v1")!, model: "qwen3:4b")))
        let data = try JSONEncoder().encode([endpoint, .appleFoundation])
        let decoded = try JSONDecoder().decode([ModelEntry].self, from: data)
        XCTAssertEqual(decoded, [endpoint, .appleFoundation])
        XCTAssertFalse(decoded[0].isLocal)   // remote host
        XCTAssertTrue(decoded[1].isLocal)    // on-device
    }

    func testChatCompletionsURLToleratesFullPath() {
        let base = EndpointConfig(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m")
        XCTAssertEqual(base.chatCompletionsURL.absoluteString, "http://localhost:11434/v1/chat/completions")
        let full = EndpointConfig(baseURL: URL(string: "http://localhost:11434/v1/chat/completions")!, model: "m")
        XCTAssertEqual(full.chatCompletionsURL.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    private func assertThrows(_ engine: EndpointRewriter, expected: ShoutError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await engine.rewrite(profile: .cleanUp, transcript: "one two three four five", languageCode: "en", glossary: [])
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ShoutError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

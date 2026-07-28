// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import CryptoKit
import XCTest
@testable import ShoutCore

/// Covers the validation gate that stands between a downloaded 1.6 GB blob and
/// native ggml. The real model isn't needed: a tiny spec with a real hash
/// exercises exactly the same code path.
final class ModelManagerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shout-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func write(_ bytes: [UInt8], as name: String = "model.bin") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func spec(bytes: [UInt8], sha: String?, fileName: String = "model.bin") -> WhisperModelSpec {
        WhisperModelSpec(
            id: "test", displayName: "Test", fileName: fileName,
            url: URL(string: "https://example.invalid/model.bin")!,
            expectedBytes: Int64(bytes.count), sha256: sha)
    }

    // MARK: - validateFile

    func testAcceptsExactSizeAndMatchingChecksum() throws {
        let bytes: [UInt8] = Array(0..<64)
        let url = try write(bytes)
        XCTAssertEqual(spec(bytes: bytes, sha: sha256(bytes)).validateFile(at: url), .ok)
    }

    /// The regression this whole gate exists for: a download interrupted near the
    /// end is large but incomplete. A minimum-size floor would wave it through.
    func testRejectsTruncatedFileEvenWhenNearlyComplete() throws {
        let full: [UInt8] = Array(repeating: 7, count: 4096)
        let truncated = Array(full.dropLast())          // 4095 of 4096 bytes
        let url = try write(truncated)
        XCTAssertEqual(
            spec(bytes: full, sha: sha256(full)).validateFile(at: url),
            .wrongSize(actual: 4095, expected: 4096))
    }

    func testRejectsPaddedFile() throws {
        let expected: [UInt8] = Array(repeating: 1, count: 100)
        let url = try write(expected + [0])
        XCTAssertEqual(
            spec(bytes: expected, sha: sha256(expected)).validateFile(at: url),
            .wrongSize(actual: 101, expected: 100))
    }

    /// Right length, wrong bytes — the case size alone can never catch.
    func testRejectsRightSizeWrongContent() throws {
        let expected: [UInt8] = Array(repeating: 2, count: 256)
        let tampered: [UInt8] = Array(repeating: 3, count: 256)
        let url = try write(tampered)
        XCTAssertEqual(
            spec(bytes: expected, sha: sha256(expected)).validateFile(at: url),
            .checksumMismatch)
    }

    func testMissingFileIsUnreadable() {
        let bytes: [UInt8] = [1, 2, 3]
        let missing = dir.appendingPathComponent("does-not-exist.bin")
        XCTAssertEqual(spec(bytes: bytes, sha: sha256(bytes)).validateFile(at: missing), .unreadable)
    }

    /// Size is checked before the hash, so a truncated file is reported as such
    /// rather than as a checksum failure — the distinction is what tells a user
    /// "retry the download" instead of "something tampered with this".
    func testSizeIsReportedBeforeChecksum() throws {
        let expected: [UInt8] = Array(repeating: 9, count: 512)
        let url = try write(Array(repeating: 8, count: 500))   // wrong size AND wrong bytes
        XCTAssertEqual(
            spec(bytes: expected, sha: sha256(expected)).validateFile(at: url),
            .wrongSize(actual: 500, expected: 512))
    }

    func testChecksumSkippedWhenNotRequested() throws {
        let expected: [UInt8] = Array(repeating: 4, count: 128)
        let url = try write(Array(repeating: 5, count: 128))   // right size, wrong bytes
        let s = spec(bytes: expected, sha: sha256(expected))
        XCTAssertEqual(s.validateFile(at: url, verifyChecksum: false), .ok)
        XCTAssertEqual(s.validateFile(at: url, verifyChecksum: true), .checksumMismatch)
    }

    /// A spec with no pin still gets the size check — it must not silently accept
    /// anything just because there's nothing to compare against.
    func testUnpinnedSpecStillChecksSize() throws {
        let expected: [UInt8] = Array(repeating: 6, count: 64)
        XCTAssertEqual(spec(bytes: expected, sha: nil).validateFile(at: try write(expected)), .ok)

        let short = dir.appendingPathComponent("short.bin")
        try Data(Array(repeating: 6, count: 63)).write(to: short)
        XCTAssertEqual(
            spec(bytes: expected, sha: nil).validateFile(at: short),
            .wrongSize(actual: 63, expected: 64))
    }

    func testChecksumComparisonIsCaseInsensitive() throws {
        let bytes: [UInt8] = Array(repeating: 10, count: 32)
        let url = try write(bytes)
        XCTAssertEqual(spec(bytes: bytes, sha: sha256(bytes).uppercased()).validateFile(at: url), .ok)
    }

    // MARK: - sha256Hex

    /// The streaming hash must agree with a one-shot hash across the 1 MB chunk
    /// boundary it reads in.
    func testStreamingHashMatchesOneShotAcrossChunkBoundary() throws {
        for count in [0, 1, (1 << 20) - 1, 1 << 20, (1 << 20) + 1] {
            let bytes = (0..<count).map { UInt8($0 % 251) }
            let url = try write(bytes, as: "chunk-\(count).bin")
            XCTAssertEqual(
                WhisperModelSpec.sha256Hex(ofFileAt: url), sha256(bytes),
                "streaming hash diverged at \(count) bytes")
        }
    }

    func testHashOfMissingFileIsNil() {
        XCTAssertNil(WhisperModelSpec.sha256Hex(ofFileAt: dir.appendingPathComponent("nope.bin")))
    }

    // MARK: - ModelManager.refresh

    func testRefreshReportsMissingWhenAbsent() {
        let bytes: [UInt8] = Array(repeating: 1, count: 32)
        let m = ModelManager(spec: spec(bytes: bytes, sha: sha256(bytes)), modelsDirectory: dir)
        XCTAssertEqual(m.state, .missing)
    }

    func testRefreshReportsReadyAtExactSize() throws {
        let bytes: [UInt8] = Array(repeating: 1, count: 32)
        _ = try write(bytes)
        let m = ModelManager(spec: spec(bytes: bytes, sha: sha256(bytes)), modelsDirectory: dir)
        XCTAssertEqual(m.state, .ready)
    }

    func testRefreshReportsMissingForTruncatedFile() throws {
        let full: [UInt8] = Array(repeating: 1, count: 32)
        _ = try write(Array(full.dropLast()))
        let m = ModelManager(spec: spec(bytes: full, sha: sha256(full)), modelsDirectory: dir)
        XCTAssertEqual(m.state, .missing, "a partial download must not present as ready")
    }

    /// refresh() intentionally skips hashing so launch isn't stalled by 1.6 GB of
    /// I/O; this documents that trade-off rather than leaving it implicit.
    func testRefreshDoesNotVerifyChecksum() throws {
        let expected: [UInt8] = Array(repeating: 1, count: 32)
        _ = try write(Array(repeating: 2, count: 32))          // right size, wrong bytes
        let m = ModelManager(spec: spec(bytes: expected, sha: sha256(expected)), modelsDirectory: dir)
        XCTAssertEqual(m.state, .ready)
    }

    func testRefreshKeepsFailureVisibleUntilNextAttempt() {
        let bytes: [UInt8] = Array(repeating: 1, count: 32)
        let m = ModelManager(spec: spec(bytes: bytes, sha: sha256(bytes)), modelsDirectory: dir)
        m.state = .failed("network down")
        m.refresh()
        XCTAssertEqual(m.state, .failed("network down"))
    }

    func testModelPathUsesInjectedDirectory() {
        let bytes: [UInt8] = [0]
        let m = ModelManager(spec: spec(bytes: bytes, sha: nil, fileName: "ggml-test.bin"),
                             modelsDirectory: dir)
        XCTAssertEqual(m.modelPath, dir.appendingPathComponent("ggml-test.bin"))
    }

    // MARK: - The shipped spec

    /// Guards the two constants that must agree with scripts/fetch-model.sh, and
    /// that the pin is a well-formed lowercase SHA-256.
    func testShippedSpecIsPinnedConsistently() {
        let s = WhisperModelSpec.largeV3Turbo
        XCTAssertEqual(s.expectedBytes, 1_624_555_275)
        XCTAssertEqual(s.sha256?.count, 64)
        XCTAssertEqual(s.sha256, s.sha256?.lowercased())
        XCTAssertTrue(s.sha256?.allSatisfy(\.isHexDigit) ?? false)
        // An immutable revision, not a branch: resolve/main would turn an
        // upstream re-publish into a checksum mismatch for every user.
        XCTAssertFalse(s.url.absoluteString.contains("/resolve/main/"))
    }
}

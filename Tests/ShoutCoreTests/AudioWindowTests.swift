// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

/// The window arithmetic behind `AudioRecorder.windows(head:tail:)`. The recorder's
/// own buffer needs a live microphone to fill, so the pure copy helper is tested
/// directly — it carries the off-by-one risk (a wrong `fromEnd` offset would feed
/// the transcriber the wrong audio, which no build error would catch).
final class AudioWindowTests: XCTestCase {
    private func copy(_ values: [Float], count: Int, fromEnd: Bool) -> [Float] {
        values.withUnsafeBufferPointer { AudioRecorder.copy($0, count: count, fromEnd: fromEnd) }
    }

    func testHeadTakesLeadingSamples() {
        XCTAssertEqual(copy([1, 2, 3, 4, 5], count: 3, fromEnd: false), [1, 2, 3])
    }

    func testTailTakesTrailingSamples() {
        XCTAssertEqual(copy([1, 2, 3, 4, 5], count: 3, fromEnd: true), [3, 4, 5])
    }

    func testSingleSampleEdges() {
        XCTAssertEqual(copy([1, 2, 3], count: 1, fromEnd: false), [1])
        XCTAssertEqual(copy([1, 2, 3], count: 1, fromEnd: true), [3])
    }

    func testFullLengthReturnsEverythingInOrder() {
        let all: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(copy(all, count: 4, fromEnd: false), all)
        XCTAssertEqual(copy(all, count: 4, fromEnd: true), all)
    }

    func testZeroCountIsEmpty() {
        XCTAssertEqual(copy([1, 2, 3], count: 0, fromEnd: false), [])
        XCTAssertEqual(copy([1, 2, 3], count: 0, fromEnd: true), [])
    }

    func testEmptySourceIsEmpty() {
        XCTAssertEqual(copy([], count: 0, fromEnd: false), [])
        XCTAssertEqual(copy([], count: 0, fromEnd: true), [])
    }

    /// The whole point of routing through `UnsafeBufferPointer`: the result must
    /// own its storage. If it shared the recorder's buffer, the next `append` on
    /// the audio render thread would copy the entire take — up to 19 MB — while
    /// holding the lock.
    func testResultDoesNotShareStorageWithSource() {
        var source: [Float] = Array(repeating: 1, count: 64)
        let head = copy(source, count: 64, fromEnd: false)
        source.withUnsafeMutableBufferPointer { buffer in
            for i in buffer.indices { buffer[i] = 99 }
        }
        XCTAssertEqual(head, Array(repeating: 1, count: 64),
                       "the copy tracked mutations of the source — storage is shared")
    }

    /// Mirrors how AppState sizes the windows: `min(requested, total)`, so a take
    /// shorter than the window yields the whole take rather than trapping.
    func testWindowsClampToAvailableSamples() {
        let take: [Float] = [1, 2, 3]
        let requested = 20 * 16_000        // Tuning.previewWindowSeconds at 16 kHz
        XCTAssertEqual(copy(take, count: min(requested, take.count), fromEnd: false), take)
        XCTAssertEqual(copy(take, count: min(requested, take.count), fromEnd: true), take)
    }

    /// Head and tail overlap while the take is shorter than both windows — the
    /// condition AppState calls `whole`, where one decode serves both consumers.
    func testHeadAndTailAgreeWhileTakeFitsBothWindows() {
        let take: [Float] = [7, 8, 9]
        XCTAssertEqual(copy(take, count: 3, fromEnd: false), copy(take, count: 3, fromEnd: true))
    }

    func testHeadAndTailDivergeOnceTakeOutgrowsWindow() {
        let take: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertNotEqual(copy(take, count: 2, fromEnd: false), copy(take, count: 2, fromEnd: true))
        XCTAssertEqual(copy(take, count: 2, fromEnd: false), [1, 2])
        XCTAssertEqual(copy(take, count: 2, fromEnd: true), [5, 6])
    }
}

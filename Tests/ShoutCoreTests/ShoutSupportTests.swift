// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

final class ShoutSupportTests: XCTestCase {

    func testWordCount() {
        XCTAssertEqual(wordCount("  hello   world "), 2)
        XCTAssertEqual(wordCount("one"), 1)
        XCTAssertEqual(wordCount(""), 0)
        XCTAssertEqual(wordCount("line one\nline two"), 4)
    }

    func testWithTimeoutReturnsFastResult() async throws {
        let value = try await withTimeout(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testWithTimeoutThrowsOnCooperativeOverrun() async {
        do {
            _ = try await withTimeout(seconds: 0.1) { () -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            XCTFail("expected timeout")
        } catch ShoutError.timeout {
            // expected
        } catch {
            XCTFail("expected ShoutError.timeout, got \(error)")
        }
    }

    /// The hard-timeout guarantee: even when the operation never observes
    /// cancellation (it blocks its thread), withTimeout must return at the
    /// deadline rather than waiting for the operation to finish.
    func testWithTimeoutIsHardEvenIfOperationIgnoresCancellation() async {
        let start = DispatchTime.now()
        // Uncooperative work: blocks its thread and never checks cancellation.
        // Kept in a synchronous closure so the (noasync) Thread.sleep isn't
        // invoked directly inside the async operation.
        let blockIgnoringCancellation: @Sendable () -> Int = {
            Thread.sleep(forTimeInterval: 1.0)
            return 1
        }
        do {
            _ = try await withTimeout(seconds: 0.2) { blockIgnoringCancellation() }
            XCTFail("expected timeout")
        } catch ShoutError.timeout {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            XCTAssertLessThan(elapsed, 0.8, "withTimeout returned at \(elapsed)s — it waited for the operation instead of the deadline")
        } catch {
            XCTFail("expected ShoutError.timeout, got \(error)")
        }
    }
}

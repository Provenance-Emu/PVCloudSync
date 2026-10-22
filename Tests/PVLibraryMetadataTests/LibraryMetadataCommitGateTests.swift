// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
import PVLibraryMetadata

final class LibraryMetadataCommitGateTests: XCTestCase {
  func testValidPermitReturnsResultAndRunsBodyExactlyOnce() throws {
    let gate = LibraryMetadataCommitGate()
    let permit = gate.issue()
    var calls = 0
    let result = try gate.withPermit(permit) {
      calls += 1
      return 42
    }
    XCTAssertEqual(result, 42)
    XCTAssertEqual(calls, 1)
  }

  func testThrownBodyPropagatesErrorAndUnlocksGate() {
    enum BodyError: Error { case failed }
    let gate = LibraryMetadataCommitGate()
    let permit = gate.issue()
    XCTAssertThrowsError(try gate.withPermit(permit) { throw BodyError.failed }) { error in
      guard case BodyError.failed = error else { return XCTFail("Unexpected error: \(error)") }
    }

    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { completed.signal() }
      gate.invalidate()
      do {
        let result = try gate.withPermit(gate.issue()) { 7 }
        XCTAssertEqual(result, 7)
      } catch { XCTFail("Gate remained unusable after throw: \(error)") }
    }
    XCTAssertEqual(completed.wait(timeout: .now() + 5), .success, "Thrown body left the gate locked")
  }

  func testInvalidatedPermitNeverEntersBody() {
    let gate = LibraryMetadataCommitGate()
    let permit = gate.issue()
    gate.invalidate()
    assertInvalidPermit {
      try gate.withPermit(permit) { XCTFail("Revoked operation entered") }
    }
  }

  func testForeignGatePermitNeverEntersBody() {
    let owner = LibraryMetadataCommitGate()
    let foreign = LibraryMetadataCommitGate()
    assertInvalidPermit {
      try foreign.withPermit(owner.issue()) { XCTFail("Foreign operation entered") }
    }
  }

  func testFreshPermitWorksAfterRepeatedInvalidation() throws {
    let gate = LibraryMetadataCommitGate()
    let original = gate.issue()
    gate.invalidate()
    let intermediate = gate.issue()
    gate.invalidate()
    assertInvalidPermit { try gate.withPermit(original) { XCTFail("Original permit revived") } }
    assertInvalidPermit { try gate.withPermit(intermediate) { XCTFail("Intermediate permit revived") } }
    XCTAssertEqual(try gate.withPermit(gate.issue()) { "fresh" }, "fresh")
  }

  func testCallbackReleasedAfterInvalidationCannotWriteFile() throws {
    let gate = LibraryMetadataCommitGate()
    let permit = gate.issue()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("metadata.json")
    let networkWaiting = DispatchSemaphore(value: 0)
    let networkResponse = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { completed.signal() }
      // Simulated network wait happens before acquiring the commit gate.
      networkWaiting.signal()
      guard networkResponse.wait(timeout: .now() + 5) == .success else {
        return XCTFail("Network response barrier timed out")
      }
      self.assertInvalidPermit {
        try gate.withPermit(permit) { try Data("{}".utf8).write(to: file) }
      }
    }
    defer { networkResponse.signal() }
    guard networkWaiting.wait(timeout: .now() + 5) == .success else {
      return XCTFail("Callback never reached network barrier")
    }
    gate.invalidate()
    networkResponse.signal()
    XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testAdmittedOperationCompletesBeforeInvalidationReturns() {
    let gate = LibraryMetadataCommitGate()
    let permit = gate.issue()
    let entered = DispatchSemaphore(value: 0)
    let releaseBody = DispatchSemaphore(value: 0)
    let invalidationStarted = DispatchSemaphore(value: 0)
    let invalidationReturned = DispatchSemaphore(value: 0)
    let operationReturned = DispatchSemaphore(value: 0)
    let events = Events()
    DispatchQueue.global().async {
      defer { operationReturned.signal() }
      do {
        try gate.withPermit(permit) {
          events.append("body entered")
          entered.signal()
          guard releaseBody.wait(timeout: .now() + 5) == .success else {
            return XCTFail("Body release barrier timed out")
          }
          events.append("body finished")
        }
      } catch { XCTFail("Admitted operation failed: \(error)") }
    }
    defer { releaseBody.signal() }
    guard entered.wait(timeout: .now() + 5) == .success else {
      return XCTFail("Operation never entered gate")
    }
    DispatchQueue.global().async {
      events.append("invalidation started")
      invalidationStarted.signal()
      gate.invalidate()
      events.append("invalidation returned")
      invalidationReturned.signal()
    }
    guard invalidationStarted.wait(timeout: .now() + 5) == .success else {
      return XCTFail("Invalidation never started")
    }
    // A bounded noncompletion check while the admitted body is held on its barrier.
    guard invalidationReturned.wait(timeout: .now() + 0.1) == .timedOut else {
      return XCTFail("Invalidation returned while the admitted body was still held")
    }
    releaseBody.signal()
    guard operationReturned.wait(timeout: .now() + 5) == .success else {
      return XCTFail("Admitted operation did not return")
    }
    guard invalidationReturned.wait(timeout: .now() + 5) == .success else {
      return XCTFail("Invalidation remained blocked after the body finished")
    }
    XCTAssertEqual(events.snapshot(), ["body entered", "invalidation started", "body finished", "invalidation returned"])
    assertInvalidPermit { try gate.withPermit(permit) { XCTFail("Old permit survived invalidation") } }
  }

  private func assertInvalidPermit(
    file: StaticString = #filePath, line: UInt = #line, operation: () throws -> Void
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      guard case LibraryMetadataCommitGate.GateError.invalidPermit = error else {
        return XCTFail("Expected invalidPermit, got \(error)", file: file, line: line)
      }
    }
  }

  private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
      lock.lock()
      defer { lock.unlock() }
      values.append(value)
    }
    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }
}

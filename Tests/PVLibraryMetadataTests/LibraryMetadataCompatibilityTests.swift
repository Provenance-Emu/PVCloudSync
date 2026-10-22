// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
import PVLibraryMetadata

final class LibraryMetadataCompatibilityTests: XCTestCase {
  private var folder: URL!
  private var recovery: URL { folder.appendingPathComponent("recovery") }
  private let identity = LibraryMetadataStore.Identity.game(gameID: "GSRE01", discNumber: 0, revision: 0)!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  func testGoldenBytesRemainIdentical() throws {
    let identities: [(String, LibraryMetadataStore.Identity)] = [
      ("game", identity),
      ("disc-revision", LibraryMetadataStore.Identity.game(gameID: " gsre01 ", discNumber: 1, revision: 7)!),
      ("homebrew", LibraryMetadataStore.Identity.contentHash(String(repeating: "AB", count: 32))!)
    ]
    let shardNames = [
      "game": "563b9655bdbd10c90681361fdc41430ebc7edac43ad6e181dd1973d50224220c.json",
      "disc-revision": "243ea5f2ec0fe06c0c542adfd816517309e07e6fee0dd0bd5c29648e99f8066d.json",
      "homebrew": "7b28e61bc1d292234192478f2c9d3b56c10ca6a386801f8d2975ea6235e674cd.json"
    ]
    let store = try LibraryMetadataStore(directoryURL: folder, recoveryDirectoryURL: recovery)
    for (name, identity) in identities {
      XCTAssertEqual(identity.fileName, shardNames[name])
      let file = folder.appendingPathComponent(identity.fileName)
      let saved = try store.commit(.init(title: "  My Game \n", coverData: Data([1, 2, 3]), tags: [" RPG ", "rpg", "Co-op", ""]), baseline: .init(), for: identity, at: Date(timeIntervalSinceReferenceDate: 123456789))
      XCTAssertEqual(saved, .init(title: "My Game", coverData: Data([1, 2, 3]), tags: ["RPG", "Co-op"]))
      // These immutable files were captured using the original app store before extraction.
      let golden = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
      XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: golden))
      _ = try store.commit(.init(), baseline: saved, for: identity, at: Date(timeIntervalSinceReferenceDate: 123456790))
      let cleared = try XCTUnwrap(Bundle.module.url(forResource: name + "-cleared", withExtension: "json", subdirectory: "Fixtures"))
      XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: cleared))
    }
  }

  func testUnknownPrimitiveTieIsCommutative() throws {
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    func snapshot(_ cached: String, _ incoming: String, name: String) throws -> Data {
      let primary = folder.appendingPathComponent(name)
      let backup = folder.appendingPathComponent(name + "Recovery")
      try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
      let file = primary.appendingPathComponent(identity.fileName)
      try Data(cached.utf8).write(to: file)
      let store = try LibraryMetadataStore(directoryURL: primary, recoveryDirectoryURL: backup, cacheCountLimit: 1)
      _ = try store.draft(for: identity)
      try Data(incoming.utf8).write(to: file)
      _ = try store.draft(for: other) // Eviction merges cached and primary unknown records.
      return try Data(contentsOf: backup.appendingPathComponent(identity.fileName))
    }
    let a = #"{"boolean":false,"number":2,"string":"a","null":null}"#
    let b = #"{"boolean":true,"number":9,"string":"z","null":"value"}"#
    let forward = try snapshot(a, b, name: "forward")
    XCTAssertEqual(forward, try snapshot(b, a, name: "reverse"))
    XCTAssertEqual(forward, Data(#"{"boolean":true,"null":null,"number":9,"string":"z"}"#.utf8))
  }

  func testBackwardClockAdvancesObservedField() throws {
    let store = try LibraryMetadataStore(directoryURL: folder, recoveryDirectoryURL: recovery)
    let initial = try store.commit(.init(title: "Old", tags: ["Keep"]), baseline: .init(), for: identity, at: Date(timeIntervalSinceReferenceDate: 123456789))
    _ = try store.commit(.init(title: "New", tags: ["Keep"]), baseline: initial, for: identity, at: Date(timeIntervalSinceReferenceDate: 1))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(identity.fileName))) as? [String: Any])
    let title = try XCTUnwrap(json[identity.rawValue + ":title"] as? [String: Any])
    let tags = try XCTUnwrap(json[identity.rawValue + ":tags"] as? [String: Any])
    XCTAssertEqual(title["updatedAt"] as? Double, Double(123456789).nextUp)
    XCTAssertEqual(tags["updatedAt"] as? Double, 123456789)
  }

  func testRecoveryFailureKeepsPrimaryAndCache() throws {
    let store = try LibraryMetadataStore(directoryURL: folder, recoveryDirectoryURL: recovery, cacheCountLimit: 1, writeRecovery: { _, _ in throw NSError(domain: "recovery", code: 1) })
    let saved = try store.commit(.init(title: "Keep", coverData: Data([1]), tags: ["Keep"]), baseline: .init(), for: identity)
    let file = folder.appendingPathComponent(identity.fileName)
    let bytes = try Data(contentsOf: file)
    let before = try store.cacheStatistics()
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    XCTAssertThrowsError(try store.commit(.init(title: "Blocked"), baseline: .init(), for: other))
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(other.fileName).path))
    XCTAssertEqual(try store.draft(for: identity), saved)
    let after = try store.cacheStatistics()
    XCTAssertEqual(after.recordCount, before.recordCount)
    XCTAssertEqual(after.retainedBytes, before.retainedBytes)
    XCTAssertEqual(after.decodedCoverBytes, before.decodedCoverBytes)
    XCTAssertEqual(try store.summary(for: identity), .init(title: "Keep", tags: ["Keep"]))
  }

  func testExactPublicLimitsAndDocumentBoundary() throws {
    XCTAssertEqual(LibraryMetadataStore.maxTitleLength, 200)
    XCTAssertEqual(LibraryMetadataStore.maxTagCount, 32)
    XCTAssertEqual(LibraryMetadataStore.maxTagLength, 40)
    XCTAssertEqual(LibraryMetadataStore.maxCoverBytes, 256 * 1024)
    XCTAssertEqual(LibraryMetadataStore.maxDocumentBytes, 1024 * 1024)
    let exact = Data(("{\"future\":\"" + String(repeating: "x", count: 1024 * 1024 - 13) + "\"}").utf8)
    XCTAssertEqual(exact.count, 1024 * 1024)
    XCTAssertNoThrow(try LibraryMetadataStore.validateDocument(data: exact, filename: identity.fileName))
    XCTAssertThrowsError(try LibraryMetadataStore.validateDocument(data: exact + Data(" ".utf8))) { error in
      guard case LibraryMetadataStore.StoreError.documentTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
    }
    let stats = LibraryMetadataStore.CacheStatistics(recordCount: 1, retainedBytes: 2, decodedCoverBytes: 3, summaryCount: 4, summaryBytes: 5)
    XCTAssertEqual(stats.summaryBytes, 5)
  }

  func testInjectedSynchronousGateRunsEachOperationOnce() throws {
    var calls = 0
    let gate: LibraryMetadataStore.FileAccess = { operation in calls += 1; try operation() }
    let store = try LibraryMetadataStore(directoryURL: folder, withFileAccess: gate, recoveryDirectoryURL: recovery)
    _ = try store.draft(for: identity)
    _ = try store.summary(for: identity)
    _ = try store.commit(.init(title: "Saved"), baseline: .init(), for: identity)
    try store.reload()
    _ = try store.cacheStatistics()
    XCTAssertEqual(calls, 5)
    let skipped = try LibraryMetadataStore(directoryURL: folder, withFileAccess: { _ in })
    XCTAssertThrowsError(try skipped.draft(for: identity)) { error in
      guard case LibraryMetadataStore.StoreError.invalidTransaction = error else { return XCTFail("Unexpected error: \(error)") }
    }
  }
}

// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
@testable import PVLibraryMetadata

final class LibraryMetadataRemoteStoreTests: XCTestCase {
  private let identity = LibraryMetadataStore.Identity.game(gameID: "GSRE01", discNumber: 0, revision: 0)!
  private var root: URL!
  private var primary: URL { root.appendingPathComponent("primary") }
  private var recovery: URL { root.appendingPathComponent("recovery") }
  private var file: URL { primary.appendingPathComponent(identity.fileName) }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func bytes(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
  private func field(_ name: String, _ value: Any, _ stamp: Any) -> [String: Any] {
    [identity.rawValue + ":" + name: ["value": value, "updatedAt": stamp]]
  }
  private func store() throws -> LibraryMetadataStore {
    try LibraryMetadataStore(directoryURL: primary, recoveryDirectoryURL: recovery)
  }
  private func golden() throws -> Data {
    try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "game", withExtension: "json", subdirectory: "Fixtures")))
  }

  func testIncomingRejectsInvalidStampsWithoutTighteningHistoricalValidation() throws {
    for name in ["title", "cover", "tags"] {
      let value: Any = name == "title" ? "Title" : NSNull()
      var invalid = try [true, false, NSNull(), "NaN", "inf", "-inf", "1e999", "nonsense", ["future": 1]].map {
        try bytes(field(name, value, $0))
      }
      invalid.append(try bytes([identity.rawValue + ":" + name: ["value": value]]))
      for data in invalid {
        XCTAssertNoThrow(try LibraryMetadataDocument.validate(data: data, filename: identity.fileName))
        XCTAssertThrowsError(try LibraryMetadataDocument.validateIncoming(data: data, for: identity)) { error in
          guard case LibraryMetadataStore.StoreError.invalidTimestamp = error else {
            return XCTFail("Expected invalidTimestamp, got \(error)")
          }
        }
      }
    }
  }

  func testIncomingAcceptsFiniteSupportedStampsAndOpaqueUnknownRecords() throws {
    for stamp: Any in [-3, 0, 2.5, "2.5", "2001-01-01T00:00:03Z"] {
      var object = field("title", "Title", stamp)
      object["future"] = ["updatedAt": true, "value": ["nested": NSNull()]]
      object[identity.rawValue + ":future"] = ["anything": "NaN"]
      XCTAssertNoThrow(try LibraryMetadataDocument.validateIncoming(data: bytes(object), for: identity))
    }
    XCTAssertNoThrow(try LibraryMetadataDocument.validateIncoming(data: Data("{}".utf8), for: identity))
    XCTAssertNoThrow(try LibraryMetadataDocument.validateIncoming(data: golden(), for: identity))
  }

  func testIncomingRequiresCanonicalIdentity() throws {
    let noncanonical = LibraryMetadataStore.Identity("game:R1NSRTAx:00:0")
    let data = try bytes([noncanonical.rawValue + ":title": ["value": "Title", "updatedAt": 1]])
    XCTAssertNoThrow(try LibraryMetadataDocument.validate(data: data, filename: noncanonical.fileName))
    XCTAssertThrowsError(try LibraryMetadataDocument.validateIncoming(data: data, for: noncanonical))
    XCTAssertThrowsError(try LibraryMetadataDocument.validateIncoming(data: Data("{}".utf8), for: noncanonical))
  }

  func testExportReturnsExactGoldenAndOpaqueCommittedBytesWithoutDraftEdits() throws {
    let data = try golden()
    try data.write(to: file)
    let subject = try store()
    var draft = try subject.draft(for: identity)
    draft.title = "Uncommitted"
    XCTAssertEqual(try subject.exportDocument(for: identity), data)
    let opaque = Data(#"{ "future": {"nested": [true,null,42]}, "other": "opaque" }"#.utf8)
    try opaque.write(to: file)
    XCTAssertEqual(try subject.exportDocument(for: identity), opaque)
    XCTAssertEqual(try Data(contentsOf: file), opaque)
  }

  func testExportReadsEmptyMissingAndRecoveryWithoutWritingPrimary() throws {
    let subject = try store()
    XCTAssertEqual(try subject.exportDocument(for: identity), Data("{}".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    let data = try golden()
    try data.write(to: recovery.appendingPathComponent(identity.fileName))
    XCTAssertEqual(try subject.exportDocument(for: identity), data)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testMergeIndependentFieldsTombstonesUnknownMembersAndOriginalStamps() throws {
    var local = field("title", "Old", 1)
    local.merge(field("cover", "AQID", 4)) { _, new in new }
    local["future"] = ["updatedAt": 9, "value": ["nested": [true, NSNull()]]]
    try bytes(local).write(to: file)
    var remote = field("title", NSNull(), "2.5")
    remote.merge(field("tags", ["New"], "2001-01-01T00:00:03Z")) { _, new in new }
    remote[identity.rawValue + ":title"] = ["value": NSNull(), "updatedAt": "2.5", "futureMember": true]
    var expected = local
    expected.merge(remote) { _, new in new }
    let result = try store().mergeDocument(bytes(remote), for: identity)
    XCTAssertEqual(result, try bytes(expected))
    XCTAssertEqual(try Data(contentsOf: file), result)
    XCTAssertEqual(try store().draft(for: identity), .init(coverData: Data([1, 2, 3]), tags: ["New"]))
  }

  func testMergeUsesLatestPrimaryInsideGateOverStaleCache() throws {
    try bytes(field("title", "Cached", 1)).write(to: file)
    var calls = 0
    let latest = try bytes(field("title", "External", 10))
    let subject = try LibraryMetadataStore(directoryURL: primary, withFileAccess: { operation in
      calls += 1
      if calls == 2 { try latest.write(to: self.file) }
      try operation()
    }, recoveryDirectoryURL: recovery)
    XCTAssertEqual(try subject.draft(for: identity).title, "Cached")
    _ = try subject.mergeDocument(bytes(field("tags", ["Remote"], 2)), for: identity)
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(try subject.draft(for: identity), .init(title: "External", tags: ["Remote"]))
  }

  func testMergeDeterministicTieAndRepeatAvoidPrimaryRewrite() throws {
    let a = try bytes(field("title", "A", 5))
    let z = try bytes(field("title", "Z", 5))
    try a.write(to: file)
    var writes = 0
    let subject = try LibraryMetadataStore(directoryURL: primary, write: { data, url in
      writes += 1; try data.write(to: url, options: .atomic)
    }, recoveryDirectoryURL: recovery)
    XCTAssertEqual(try subject.mergeDocument(z, for: identity), z)
    XCTAssertEqual(try subject.mergeDocument(z, for: identity), z)
    XCTAssertEqual(try subject.mergeDocument(a, for: identity), z)
    XCTAssertEqual(writes, 1)
    try z.write(to: file)
    XCTAssertEqual(try store().mergeDocument(a, for: identity), z)
  }

  func testLostPrimaryUsesCacheThenEvictedRecoveryWithoutLosingFields() throws {
    let data = try golden()
    try data.write(to: file)
    let subject = try LibraryMetadataStore(directoryURL: primary, recoveryDirectoryURL: recovery, cacheCountLimit: 1)
    _ = try subject.draft(for: identity)
    try FileManager.default.removeItem(at: file)
    XCTAssertEqual(try subject.exportDocument(for: identity), data)
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    _ = try subject.draft(for: other)
    XCTAssertEqual(try subject.exportDocument(for: identity), data)
    let result = try subject.mergeDocument(bytes(field("tags", ["New"], 123456790)), for: identity)
    XCTAssertEqual(try LibraryMetadataDocument.draft(from: result, for: identity),
      .init(title: "My Game", coverData: Data([1, 2, 3]), tags: ["New"]))
    XCTAssertEqual(try Data(contentsOf: file), result)
  }

  func testLostPrimaryMergeUsesRetainedCacheAndUnavailableRecoveryThrows() throws {
    let subject = try store()
    let saved = try subject.commit(.init(title: "Keep"), baseline: .init(), for: identity, at: Date(timeIntervalSinceReferenceDate: 1))
    try FileManager.default.removeItem(at: file)
    _ = try subject.mergeDocument(bytes(field("tags", ["New"], 2)), for: identity)
    XCTAssertEqual(try subject.draft(for: identity), .init(title: saved.title, tags: ["New"]))
    // A previously seen evicted shard cannot silently become an empty document.
    let limited = try LibraryMetadataStore(directoryURL: primary, recoveryDirectoryURL: recovery, cacheCountLimit: 1)
    _ = try limited.draft(for: identity)
    _ = try limited.draft(for: LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.removeItem(at: recovery.appendingPathComponent(identity.fileName))
    XCTAssertThrowsError(try limited.exportDocument(for: identity))
    XCTAssertThrowsError(try limited.mergeDocument(Data("{}".utf8), for: identity))
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testInvalidRemotePreservesDiskAndCachedProjection() throws {
    let data = try golden()
    try data.write(to: file)
    let subject = try store()
    let saved = try subject.draft(for: identity)
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    let wrong = try bytes([other.rawValue + ":title": ["value": "Wrong", "updatedAt": 1]])
    for invalid in [Data("broken".utf8), Data("[]".utf8), wrong,
      Data(repeating: 32, count: LibraryMetadataStore.maxDocumentBytes + 1),
      try bytes(field("title", "Bad", true)), try bytes(field("cover", "!bad", 3))] {
      XCTAssertThrowsError(try subject.mergeDocument(invalid, for: identity))
      XCTAssertEqual(try Data(contentsOf: file), data)
      XCTAssertEqual(try subject.draft(for: identity), saved)
    }
  }

  func testCorruptPrimaryExportAndMergeKeepEvidenceAndCache() throws {
    try golden().write(to: file)
    let subject = try store()
    let saved = try subject.draft(for: identity)
    let corrupt = Data("broken".utf8)
    try corrupt.write(to: file)
    XCTAssertThrowsError(try subject.exportDocument(for: identity))
    XCTAssertThrowsError(try subject.mergeDocument(bytes(field("title", "New", 123456790)), for: identity))
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
    XCTAssertEqual(try subject.draft(for: identity), saved)
  }

  func testPrimaryWriteFailurePreservesPreviouslyVisibleCacheAndBytes() throws {
    let data = try golden()
    try data.write(to: file)
    let subject = try LibraryMetadataStore(directoryURL: primary, write: { _, _ in
      throw NSError(domain: "primaryWrite", code: 1)
    }, recoveryDirectoryURL: recovery)
    let saved = try subject.draft(for: identity)
    XCTAssertThrowsError(try subject.mergeDocument(bytes(field("title", "New", 123456790)), for: identity))
    XCTAssertEqual(try Data(contentsOf: file), data)
    XCTAssertEqual(try subject.draft(for: identity), saved)
    XCTAssertEqual(try subject.exportDocument(for: identity), data)
  }

  func testEvictionRecoveryFailureHappensBeforePrimaryWriteOrCacheAdoption() throws {
    let data = try golden()
    try data.write(to: file)
    var writes = 0
    let subject = try LibraryMetadataStore(directoryURL: primary, write: { data, url in
      writes += 1; try data.write(to: url, options: .atomic)
    }, recoveryDirectoryURL: recovery, cacheCountLimit: 1, writeRecovery: { _, _ in
      throw NSError(domain: "recoveryWrite", code: 1)
    })
    let saved = try subject.draft(for: identity)
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    let remote = try bytes([other.rawValue + ":title": ["value": "New", "updatedAt": 1]])
    XCTAssertThrowsError(try subject.mergeDocument(remote, for: other))
    XCTAssertEqual(writes, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: primary.appendingPathComponent(other.fileName).path))
    XCTAssertEqual(try subject.draft(for: identity), saved)
    XCTAssertEqual(try subject.cacheStatistics().recordCount, 1)
    XCTAssertEqual(try Data(contentsOf: file), data)
  }

  func testPublicExportAndMergeEachEnterInjectedGateOnceIncludingInvalidRemote() throws {
    var calls = 0
    let subject = try LibraryMetadataStore(directoryURL: primary, withFileAccess: { operation in
      calls += 1; try operation()
    }, recoveryDirectoryURL: recovery)
    XCTAssertEqual(try subject.exportDocument(for: identity), Data("{}".utf8))
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(try subject.mergeDocument(Data("{}".utf8), for: identity), Data("{}".utf8))
    XCTAssertEqual(calls, 2)
    XCTAssertThrowsError(try subject.mergeDocument(Data("broken".utf8), for: identity))
    XCTAssertEqual(calls, 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }
}

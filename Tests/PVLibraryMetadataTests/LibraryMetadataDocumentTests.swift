// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
import PVLibraryMetadata

final class LibraryMetadataDocumentTests: XCTestCase {
  private let identity = LibraryMetadataStore.Identity.game(gameID: "GSRE01", discNumber: 0, revision: 0)!
  private func bytes(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
  private func record(_ field: String, _ value: Any, _ stamp: Any) -> [String: Any] {
    [identity.rawValue + ":" + field: ["value": value, "updatedAt": stamp]]
  }
  private func golden(_ name: String) throws -> Data {
    try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
  }

  func testGoldenValidationAndAllProjectionFields() throws {
    let data = try golden("game")
    try LibraryMetadataDocument.validate(data: data, filename: identity.fileName)
    XCTAssertEqual(try LibraryMetadataDocument.draft(from: data, for: identity),
      .init(title: "My Game", coverData: Data([1, 2, 3]), tags: ["RPG", "Co-op"]))
    XCTAssertEqual(try LibraryMetadataDocument.summary(from: data, for: identity),
      .init(title: "My Game", tags: ["RPG", "Co-op"]))
    XCTAssertEqual(try LibraryMetadataDocument.draft(from: golden("game-cleared"), for: identity), .init())
    for name in ["disc-revision", "disc-revision-cleared", "homebrew", "homebrew-cleared"] {
      try LibraryMetadataDocument.validate(data: golden(name))
    }
  }

  func testProjectionNormalizesWithoutChangingBytesAndSummaryValidatesCover() throws {
    var object = record("title", "  Title \n", 1)
    object.merge(record("tags", [" RPG ", "rpg", "", "Co-op"], 1)) { _, new in new }
    object.merge(record("cover", "AQID", 1)) { _, new in new }
    let data = try bytes(object)
    XCTAssertEqual(try LibraryMetadataDocument.draft(from: data, for: identity),
      .init(title: "Title", coverData: Data([1, 2, 3]), tags: ["RPG", "Co-op"]))
    XCTAssertEqual(try LibraryMetadataDocument.summary(from: data, for: identity), .init(title: "Title", tags: ["RPG", "Co-op"]))
    XCTAssertThrowsError(try LibraryMetadataDocument.summary(from: bytes(record("cover", "!bad", 1)), for: identity))
  }

  func testIndependentFieldMergePreservesNullAndNestedUnknownData() throws {
    var local = record("title", "Old", 1)
    local.merge(record("cover", "AQID", 4)) { _, new in new }
    local["future"] = ["updatedAt": 7, "nested": ["null": NSNull(), "array": [1, 2]]]
    var remote = record("title", NSNull(), 2)
    remote.merge(record("tags", ["New"], 3)) { _, new in new }
    remote[identity.rawValue + ":title"] = ["value": NSNull(), "updatedAt": 2, "futureOption": ["a": true]]
    let merged = try LibraryMetadataDocument.merge(local: bytes(local), remote: bytes(remote), for: identity)
    XCTAssertEqual(try LibraryMetadataDocument.draft(from: merged, for: identity), .init(coverData: Data([1, 2, 3]), tags: ["New"]))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? NSDictionary)
    XCTAssertEqual(object["future"] as? NSDictionary, local["future"] as? NSDictionary)
    XCTAssertEqual(object[identity.rawValue + ":title"] as? NSDictionary, remote[identity.rawValue + ":title"] as? NSDictionary)
  }

  func testEqualStampUnknownPrimitiveTiesUseFragmentBytes() throws {
    let a = Data(#"{"boolean":false,"number":2,"string":"a","null":null}"#.utf8)
    let b = Data(#"{"boolean":true,"number":9,"string":"z","null":"value"}"#.utf8)
    let expected = Data(#"{"boolean":true,"null":null,"number":9,"string":"z"}"#.utf8)
    XCTAssertEqual(try LibraryMetadataDocument.merge(local: a, remote: b, for: identity), expected)
    XCTAssertEqual(try LibraryMetadataDocument.merge(local: b, remote: a, for: identity), expected)
  }

  func testSupportedTimestampFormsAndNonfiniteUnknownStamps() throws {
    for stamp: Any in [2.5, "2.5", "2001-01-01T00:00:03Z"] {
      let result = try LibraryMetadataDocument.merge(local: bytes(record("title", "Old", 2)), remote: bytes(record("title", "New", stamp)), for: identity)
      XCTAssertEqual(try LibraryMetadataDocument.draft(from: result, for: identity).title, "New")
    }
    for stamp: Any in ["nan", "inf", "-inf", "1e999", NSNull(), ["unknown": true]] {
      let local = try bytes(["future": ["updatedAt": stamp, "value": "Old"]])
      let remote = try bytes(["future": ["updatedAt": -100, "value": "New"]])
      XCTAssertEqual(try LibraryMetadataDocument.merge(local: local, remote: remote, for: identity), remote)
    }
    let missing = try bytes(["future": ["value": "Old"]])
    let finite = try bytes(["future": ["updatedAt": -100, "value": "New"]])
    XCTAssertEqual(try LibraryMetadataDocument.merge(local: missing, remote: finite, for: identity), finite)
  }

  func testMergeIsCommutativeAssociativeAndIdempotent() throws {
    let a = try golden("game")
    let b = try golden("game-cleared")
    let c = try bytes(record("tags", ["Latest"], 123456791))
    func merge(_ x: Data, _ y: Data) throws -> Data { try LibraryMetadataDocument.merge(local: x, remote: y, for: identity) }
    XCTAssertEqual(try merge(a, a), a)
    XCTAssertEqual(try merge(a, b), try merge(b, a))
    XCTAssertEqual(try merge(merge(a, b), c), try merge(a, merge(b, c)))
  }

  func testEmptyMergeNeedsOnlyFilename() throws {
    let empty = Data("{}".utf8)
    XCTAssertEqual(try LibraryMetadataDocument.merge(local: empty, remote: empty, filename: identity.fileName), empty)
    let opaque = Data(#"{"future":null}"#.utf8)
    XCTAssertEqual(try LibraryMetadataDocument.merge(local: empty, remote: opaque, filename: identity.fileName), opaque)
    XCTAssertEqual(try LibraryMetadataDocument.draft(from: empty, for: identity), .init())
  }

  func testValidationAndMergingRejectWrongShardMalformedAndOversize() throws {
    let valid = try golden("game")
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    XCTAssertThrowsError(try LibraryMetadataDocument.draft(from: valid, for: other))
    XCTAssertThrowsError(try LibraryMetadataDocument.summary(from: valid, for: other))
    for invalid in [Data("[]".utf8), Data("broken".utf8), Data(repeating: 32, count: 1024 * 1024 + 1), try bytes(record("title", 42, 1))] {
      XCTAssertThrowsError(try LibraryMetadataDocument.validate(data: invalid))
      XCTAssertThrowsError(try LibraryMetadataDocument.merge(local: valid, remote: invalid, for: identity))
      XCTAssertThrowsError(try LibraryMetadataDocument.merge(local: invalid, remote: valid, for: identity))
    }
    XCTAssertThrowsError(try LibraryMetadataDocument.merge(local: valid, remote: Data("{}".utf8), for: other))
    XCTAssertThrowsError(try LibraryMetadataDocument.merge(local: valid, remote: valid, filename: "../" + identity.fileName))
    let largeA = try bytes(["a": String(repeating: "a", count: 600000)])
    let largeB = try bytes(["b": String(repeating: "b", count: 600000)])
    XCTAssertThrowsError(try LibraryMetadataDocument.merge(local: largeA, remote: largeB, for: identity))
  }

  func testRecoveryValidatesFinalMergeAfterLaterSourceShrinksRecord() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let primary = folder.appendingPathComponent("primary")
    let recovery = folder.appendingPathComponent("recovery")
    try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    let file = primary.appendingPathComponent(identity.fileName)
    let large = String(repeating: "x", count: 600000)
    try bytes(["a": ["updatedAt": 1, "value": large]]).write(to: file)
    let store = try LibraryMetadataStore(directoryURL: primary, recoveryDirectoryURL: recovery, cacheCountLimit: 1)
    _ = try store.draft(for: identity)
    try bytes(["b": ["updatedAt": 2, "value": large]]).write(to: file)
    try bytes(["a": ["updatedAt": 3, "value": "tiny"]]).write(to: recovery.appendingPathComponent(identity.fileName))
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    XCTAssertNoThrow(try store.draft(for: other))
    let result = try Data(contentsOf: recovery.appendingPathComponent(identity.fileName))
    XCTAssertEqual(result, try bytes(["a": ["updatedAt": 3, "value": "tiny"], "b": ["updatedAt": 2, "value": large]]))
  }

  func testCanonicalIdentityParserRoundTripsGamesWADAndContent() {
    for value in [identity,
      LibraryMetadataStore.Identity.game(gameID: "WAD-ID-LONG", discNumber: Int.max, revision: 7)!,
      LibraryMetadataStore.Identity.contentHash(String(repeating: "ab", count: 32))!] {
      XCTAssertEqual(LibraryMetadataStore.Identity.parseCanonical(value.rawValue), value)
    }
  }

  func testCanonicalIdentityParserRejectsNoncanonicalAndInvalidForms() {
    let invalid = ["", "other:abc", "game:R1NSRTAx:0", "game:R1NSRTAx:0:0:extra", "game:!!!!:0:0",
      "game:/w==:0:0", "game:Z3NyZTAx:0:0", "game:IFNPTUU=:0:0", "game::0:0",
      "game:PFVOS05PV04+:0:0", "game:SUQtWA==:0:0", "game:R1NSRTAx:-1:0", "game:R1NSRTAx:0:-1",
      "game:R1NSRTAx:00:0", "game:R1NSRTAx:+1:0", "game:R1NSRTAx:0:01", "game:R1NSRTAx:9223372036854775808:0",
      "game:R1NSRTAx:0:999999999999999999999999", "sha256:" + String(repeating: "AB", count: 32),
      "sha256:" + String(repeating: "g", count: 64), "sha256:ab", "sha256:" + String(repeating: "ab", count: 32) + ":extra"]
    for raw in invalid { XCTAssertNil(LibraryMetadataStore.Identity.parseCanonical(raw), raw) }
  }
}

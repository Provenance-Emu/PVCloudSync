// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
import PVLibraryMetadata

final class LibraryMetadataExchangeTests: XCTestCase {
  private let game = "game:R1NSRTAx:0:0"
  private let sha = String(repeating: "ab", count: 32)
  private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
  private func evidence(_ sha: Any = NSNull(), bytes: UInt64 = 1, kind: String = "disc") -> [String: Any] {
    ["sha256": sha, "byteCount": bytes, "kind": kind]
  }
  private func entry(_ identity: String? = nil) -> [String: Any] {
    ["identity": identity ?? game, "digest": sha, "evidence": evidence()]
  }
  private func body(_ value: Any = "Name", stamp: Any = 1) throws -> Data {
    try json([game + ":title": ["value": value, "updatedAt": stamp]])
  }
  private func envelope(_ data: Data, identity: String? = nil) throws -> Data {
    try json(["identity": identity ?? game, "document": data.base64EncodedString()])
  }

  func testManifestRoundTripAndOpaqueCursor() throws {
    let disc = try LibraryEditsContentEvidence(sha256: nil, byteCount: UInt64.max, kind: .disc)
    let content = try LibraryEditsContentEvidence(sha256: sha, byteCount: 42, kind: .content)
    let page = try LibraryEditsManifestPage(entries: [
      .init(identity: game, digest: sha, evidence: disc),
      .init(identity: "sha256:" + sha, digest: String(repeating: "cd", count: 32), evidence: content)
    ], nextCursor: "future://opaque?token=α/+=\n")
    XCTAssertEqual(try LibraryEditsWireCodec.decodeManifest(LibraryEditsWireCodec.encode(page)), page)
    XCTAssertEqual(try JSONDecoder().decode(LibraryEditsManifestPage.self, from: JSONEncoder().encode(page)), page)
    XCTAssertNil(page.entries[0].evidence.sha256)
    XCTAssertEqual(page.entries[1].evidence.sha256, sha)
    XCTAssertNoThrow(try LibraryEditsManifestPage(entries: [], nextCursor: nil))
  }

  func testEvidenceValidationAppliesToInitializersAndDecoding() throws {
    for sha in ["", "ab", String(repeating: "AB", count: 32), String(repeating: "g", count: 64)] {
      XCTAssertThrowsError(try LibraryEditsContentEvidence(sha256: sha, byteCount: 1, kind: .disc))
      XCTAssertThrowsError(try JSONDecoder().decode(LibraryEditsContentEvidence.self, from: json(evidence(sha))))
    }
    XCTAssertThrowsError(try LibraryEditsContentEvidence(sha256: nil, byteCount: 0, kind: .disc))
    for object in [evidence(bytes: 0), evidence(kind: "future")] {
      XCTAssertThrowsError(try JSONDecoder().decode(LibraryEditsContentEvidence.self, from: json(object)))
    }
    XCTAssertNoThrow(try LibraryEditsContentEvidence(sha256: sha, byteCount: 1, kind: .disc))
  }

  func testEntryRejectsInvalidIdentityDigestAndEvidenceBinding() throws {
    let disc = try LibraryEditsContentEvidence(sha256: nil, byteCount: 1, kind: .disc)
    let content = try LibraryEditsContentEvidence(sha256: sha, byteCount: 1, kind: .content)
    let noHash = try LibraryEditsContentEvidence(sha256: nil, byteCount: 1, kind: .content)
    for identity in ["", "../file", "game:R1NSRTAx:00:0", "sha256:" + sha.uppercased()] {
      XCTAssertThrowsError(try LibraryEditsManifestEntry(identity: identity, digest: sha, evidence: disc))
      XCTAssertThrowsError(try JSONDecoder().decode(LibraryEditsManifestEntry.self, from: json(entry(identity))))
    }
    for digest in ["", "ab", sha.uppercased(), String(repeating: "z", count: 64)] {
      XCTAssertThrowsError(try LibraryEditsManifestEntry(identity: game, digest: digest, evidence: disc))
      var object = entry(); object["digest"] = digest
      XCTAssertThrowsError(try JSONDecoder().decode(LibraryEditsManifestEntry.self, from: json(object)))
    }
    for (identity, claim) in [(game, content), ("sha256:" + sha, disc), ("sha256:" + sha, noHash),
      ("sha256:" + String(repeating: "cd", count: 32), content)] {
      XCTAssertThrowsError(try LibraryEditsManifestEntry(identity: identity, digest: sha, evidence: claim))
      let object: [String: Any] = ["identity": identity, "digest": sha,
        "evidence": try JSONSerialization.jsonObject(with: JSONEncoder().encode(claim))]
      XCTAssertThrowsError(try JSONDecoder().decode(LibraryEditsManifestEntry.self, from: json(object)))
    }
  }

  func testManifestEntryAndUTF8CursorBoundaries() throws {
    let disc = try LibraryEditsContentEvidence(sha256: nil, byteCount: 1, kind: .disc)
    let entries = try (0..<129).map {
      try LibraryEditsManifestEntry(identity: "game:R1NSRTAx:\($0):0", digest: sha, evidence: disc)
    }
    let cursor = String(repeating: "é", count: 512)
    let valid = try LibraryEditsManifestPage(entries: Array(entries.prefix(128)), nextCursor: cursor)
    XCTAssertEqual(try LibraryEditsWireCodec.decodeManifest(LibraryEditsWireCodec.encode(valid)), valid)
    for (items, token) in [(entries, cursor), ([entries[0], entries[0]], cursor), ([], cursor + "a")] {
      XCTAssertThrowsError(try LibraryEditsManifestPage(entries: items, nextCursor: token))
      let object: [String: Any] = ["entries": try JSONSerialization.jsonObject(with: JSONEncoder().encode(items)), "nextCursor": token]
      XCTAssertThrowsError(try LibraryEditsWireCodec.decodeManifest(json(object)))
    }
  }

  func testDocumentPreservesExactGoldenAndOpaqueFutureBytes() throws {
    let fixture = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "game", withExtension: "json", subdirectory: "Fixtures")))
    let opaque = Data((" {\n \"future\": {\"nested\":[null,true,{\"x\":1}],\"updatedAt\":\"unknown\"},\n \"" + game + ":title\": {\"value\":\" A \",\"updatedAt\":1,\"future\":42} } \n").utf8)
    for bytes in [fixture, opaque] {
      let document = try LibraryEditsDocument(identity: game, document: bytes)
      XCTAssertEqual(document.document, bytes)
      let decoded = try LibraryEditsWireCodec.decodeDocument(LibraryEditsWireCodec.encode(document))
      XCTAssertEqual(decoded, document)
      XCTAssertEqual(decoded.document, bytes)
    }
  }

  func testDocumentRejectsInvalidBodiesTimestampsBase64AndIdentities() throws {
    for stamp: Any in [NSNull(), true, "nan", "infinity", "not-a-date", ["future": 1]] {
      let bytes = try body(stamp: stamp)
      XCTAssertThrowsError(try LibraryEditsDocument(identity: game, document: bytes))
      XCTAssertThrowsError(try LibraryEditsWireCodec.decodeDocument(envelope(bytes)))
    }
    for bytes in [Data("[]".utf8), Data("bad".utf8), try body(42)] {
      XCTAssertThrowsError(try LibraryEditsDocument(identity: game, document: bytes))
      XCTAssertThrowsError(try LibraryEditsWireCodec.decodeDocument(envelope(bytes)))
    }
    for identity in ["../file", "game:R1NSRTAx:00:0", "game:T1RIRVI=:0:0"] {
      XCTAssertThrowsError(try LibraryEditsDocument(identity: identity, document: body()))
      XCTAssertThrowsError(try LibraryEditsWireCodec.decodeDocument(envelope(body(), identity: identity)))
    }
    XCTAssertThrowsError(try LibraryEditsWireCodec.decodeDocument(json(["identity": game, "document": "!bad"])))
    for stamp: Any in [1.5, "1.5", "2001-01-01T00:00:03Z"] {
      XCTAssertNoThrow(try LibraryEditsDocument(identity: game, document: body(stamp: stamp)))
    }
  }

  func testExactShardLimitAndOversizedDecodedBody() throws {
    let prefix = Data(#"{"future":""#.utf8), suffix = Data(#""}"#.utf8)
    let bytes = prefix + Data(repeating: 120, count: 1024 * 1024 - prefix.count - suffix.count) + suffix
    let document = try LibraryEditsDocument(identity: game, document: bytes)
    XCTAssertEqual(try LibraryEditsWireCodec.decodeDocument(LibraryEditsWireCodec.encode(document)), document)
    let oversized = bytes + Data([32])
    XCTAssertThrowsError(try LibraryEditsDocument(identity: game, document: oversized)) {
      XCTAssertEqual($0 as? LibraryEditsWireError, .documentTooLarge)
    }
    XCTAssertThrowsError(try LibraryEditsWireCodec.decodeDocument(envelope(oversized))) {
      XCTAssertEqual($0 as? LibraryEditsWireError, .documentTooLarge)
    }
  }

  func testRawBoundsPrecedeJSONDecodingAndAllowExactLimits() throws {
    let manifest = try json(["entries": []])
    let document = try envelope(Data("{}".utf8))
    XCTAssertNoThrow(try LibraryEditsWireCodec.decodeManifest(manifest + Data(repeating: 32, count: 256 * 1024 - manifest.count)))
    XCTAssertNoThrow(try LibraryEditsWireCodec.decodeDocument(document + Data(repeating: 32, count: 2 * 1024 * 1024 - document.count)))
    XCTAssertThrowsError(try LibraryEditsWireCodec.decodeManifest(Data(repeating: 33, count: 256 * 1024 + 1))) {
      XCTAssertEqual($0 as? LibraryEditsWireError, .manifestTooLarge)
    }
    XCTAssertThrowsError(try LibraryEditsWireCodec.decodeDocument(Data(repeating: 33, count: 2 * 1024 * 1024 + 1))) {
      XCTAssertEqual($0 as? LibraryEditsWireError, .envelopeTooLarge)
    }
  }

  func testEncodingEnforcesFinalEnvelopeBounds() throws {
    let disc = try LibraryEditsContentEvidence(sha256: nil, byteCount: 1, kind: .disc)
    let longID = LibraryMetadataStore.Identity.game(gameID: String(repeating: "A", count: 2100), discNumber: 0, revision: 0)!.rawValue
    let entries = try (0..<128).map {
      try LibraryEditsManifestEntry(identity: longID.replacingOccurrences(of: ":0:0", with: ":\($0):0"), digest: sha, evidence: disc)
    }
    XCTAssertThrowsError(try LibraryEditsWireCodec.encode(LibraryEditsManifestPage(entries: entries, nextCursor: nil))) {
      XCTAssertEqual($0 as? LibraryEditsWireError, .manifestTooLarge)
    }
    let hugeID = LibraryMetadataStore.Identity.game(gameID: String(repeating: "A", count: 1600 * 1024), discNumber: 0, revision: 0)!.rawValue
    let document = try LibraryEditsDocument(identity: hugeID, document: Data("{}".utf8))
    XCTAssertThrowsError(try LibraryEditsWireCodec.encode(document)) {
      XCTAssertEqual($0 as? LibraryEditsWireError, .envelopeTooLarge)
    }
  }
}

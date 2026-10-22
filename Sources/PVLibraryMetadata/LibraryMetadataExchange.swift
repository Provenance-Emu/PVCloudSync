// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Admission failures for shared library metadata wire values. JSON syntax and
/// underlying document validation errors retain their original error types.
public enum LibraryEditsWireError: Error, Equatable, Sendable {
  case invalidSHA256, invalidByteCount, invalidIdentity, invalidDigest, evidenceMismatch
  case tooManyEntries, duplicateIdentity, cursorTooLarge
  case manifestTooLarge, documentTooLarge, envelopeTooLarge
}

private func isWireSHA256(_ value: String) -> Bool {
  value.utf8.count == 64 && value.utf8.allSatisfy {
    (48...57).contains($0) || (97...102).contains($0)
  }
}

/// A remote claim, never proof of a local file's identity. Before binding an
/// entry locally, a provider must independently verify header/stat evidence or
/// an import receipt. Paths and credentials are deliberately absent.
public struct LibraryEditsContentEvidence: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case disc, content
  }

  public let sha256: String?
  public let byteCount: UInt64
  public let kind: Kind

  public init(sha256: String?, byteCount: UInt64, kind: Kind) throws {
    if let sha256, !isWireSHA256(sha256) { throw LibraryEditsWireError.invalidSHA256 }
    guard byteCount > 0 else { throw LibraryEditsWireError.invalidByteCount }
    self.sha256 = sha256
    self.byteCount = byteCount
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey { case sha256, byteCount, kind }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(sha256: values.decodeIfPresent(String.self, forKey: .sha256),
      byteCount: values.decode(UInt64.self, forKey: .byteCount),
      kind: values.decode(Kind.self, forKey: .kind))
  }
}

/// One canonical metadata shard and the digest of its committed document bytes.
/// Content evidence must name the same SHA-256 as the content identity; disc
/// evidence may omit a content hash. Evidence remains an untrusted remote claim.
public struct LibraryEditsManifestEntry: Codable, Equatable, Sendable {
  public let identity: String
  public let digest: String
  public let evidence: LibraryEditsContentEvidence

  public init(identity: String, digest: String, evidence: LibraryEditsContentEvidence) throws {
    guard LibraryMetadataStore.Identity.parseCanonical(identity) != nil else {
      throw LibraryEditsWireError.invalidIdentity
    }
    guard isWireSHA256(digest) else { throw LibraryEditsWireError.invalidDigest }
    switch evidence.kind {
    case .disc:
      guard identity.hasPrefix("game:") else { throw LibraryEditsWireError.evidenceMismatch }
    case .content:
      guard let sha256 = evidence.sha256, identity == "sha256:" + sha256 else {
        throw LibraryEditsWireError.evidenceMismatch
      }
    }
    self.identity = identity
    self.digest = digest
    self.evidence = evidence
  }

  private enum CodingKeys: String, CodingKey { case identity, digest, evidence }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(identity: values.decode(String.self, forKey: .identity),
      digest: values.decode(String.self, forKey: .digest),
      evidence: values.decode(LibraryEditsContentEvidence.self, forKey: .evidence))
  }
}

public struct LibraryEditsManifestPage: Codable, Equatable, Sendable {
  public static let maxEntries = 128
  public static let maxCursorBytes = 1024

  public let entries: [LibraryEditsManifestEntry]
  /// Opaque server cursor. No normalization or client interpretation is applied.
  public let nextCursor: String?

  public init(entries: [LibraryEditsManifestEntry], nextCursor: String?) throws {
    guard entries.count <= Self.maxEntries else { throw LibraryEditsWireError.tooManyEntries }
    guard Set(entries.map(\.identity)).count == entries.count else {
      throw LibraryEditsWireError.duplicateIdentity
    }
    guard (nextCursor?.utf8.count ?? 0) <= Self.maxCursorBytes else {
      throw LibraryEditsWireError.cursorTooLarge
    }
    self.entries = entries
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey { case entries, nextCursor }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(entries: values.decode([LibraryEditsManifestEntry].self, forKey: .entries),
      nextCursor: values.decodeIfPresent(String.self, forKey: .nextCursor))
  }
}

/// A validated remote shard. The committed document bytes remain exact: decoding
/// and encoding this envelope never restamp or canonicalize its payload.
public struct LibraryEditsDocument: Codable, Equatable, Sendable {
  public static let maxDocumentBytes = LibraryMetadataStore.maxDocumentBytes

  public let identity: String
  public let document: Data

  public init(identity: String, document: Data) throws {
    guard document.count <= Self.maxDocumentBytes else { throw LibraryEditsWireError.documentTooLarge }
    guard let parsed = LibraryMetadataStore.Identity.parseCanonical(identity) else {
      throw LibraryEditsWireError.invalidIdentity
    }
    try LibraryMetadataDocument.validateIncoming(data: document, for: parsed)
    self.identity = identity
    self.document = document
  }

  private enum CodingKeys: String, CodingKey { case identity, document }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(identity: values.decode(String.self, forKey: .identity),
      document: values.decode(Data.self, forKey: .document))
  }
}

/// Use these entry points at the network boundary to bound raw bytes before
/// JSON/base64 decoding. Direct Codable use still validates each model's fields.
public enum LibraryEditsWireCodec {
  public static let maxManifestBytes = 256 * 1024
  public static let maxEnvelopeBytes = 2 * 1024 * 1024

  public static func decodeManifest(_ data: Data) throws -> LibraryEditsManifestPage {
    guard data.count <= maxManifestBytes else { throw LibraryEditsWireError.manifestTooLarge }
    return try JSONDecoder().decode(LibraryEditsManifestPage.self, from: data)
  }

  public static func decodeDocument(_ data: Data) throws -> LibraryEditsDocument {
    guard data.count <= maxEnvelopeBytes else { throw LibraryEditsWireError.envelopeTooLarge }
    return try JSONDecoder().decode(LibraryEditsDocument.self, from: data)
  }

  public static func encode(_ page: LibraryEditsManifestPage) throws -> Data {
    let data = try JSONEncoder().encode(page)
    guard data.count <= maxManifestBytes else { throw LibraryEditsWireError.manifestTooLarge }
    return data
  }

  public static func encode(_ document: LibraryEditsDocument) throws -> Data {
    let data = try JSONEncoder().encode(document)
    guard data.count <= maxEnvelopeBytes else { throw LibraryEditsWireError.envelopeTooLarge }
    return data
  }
}

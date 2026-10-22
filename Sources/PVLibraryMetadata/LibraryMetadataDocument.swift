// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Stateless codec and per-record merge for custom library metadata shards.
/// Unknown records and nested fields remain opaque for schema compatibility.
public enum LibraryMetadataDocument {
  typealias Identity = LibraryMetadataStore.Identity
  typealias Draft = LibraryMetadataStore.Draft
  typealias StoreError = LibraryMetadataStore.StoreError

  public static func validate(data: Data, filename: String? = nil) throws {
    _ = try decodeDocument(data, filename: filename)
  }

  public static func draft(from data: Data, for identity: LibraryMetadataStore.Identity) throws -> LibraryMetadataStore.Draft {
    try project(decodeDocument(data, filename: identity.fileName), for: identity)
  }

  /// Validates cover encoding without allocating decoded cover bytes.
  public static func summary(from data: Data, for identity: LibraryMetadataStore.Identity) throws -> LibraryMetadataStore.Summary {
    let fields = try project(decodeDocument(data, filename: identity.fileName), for: identity, includeCover: false)
    return .init(title: fields.title, tags: fields.tags)
  }

  public static func merge(local: Data, remote: Data, for identity: LibraryMetadataStore.Identity) throws -> Data {
    try merge(local: local, remote: remote, filename: identity.fileName)
  }

  /// Each root key independently keeps the greatest timestamp, then canonical
  /// fragment bytes. Null tombstones and opaque primitive records participate.
  public static func merge(local: Data, remote: Data, filename: String) throws -> Data {
    let localObject = try decodeDocument(local, filename: filename)
    let remoteObject = try decodeDocument(remote, filename: filename)
    let merged = try mergeObjects(local: localObject, remote: remoteObject)
    let result = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    try validate(data: result, filename: filename)
    return result
  }

  // Recovery combines all validated sources before enforcing the final size,
  // preserving its historical failure semantics when later records shrink.
  static func mergeObjects(local: [String: Any], remote: [String: Any]) throws -> [String: Any] {
    var merged = local
    for (key, incoming) in remote {
      guard let current = merged[key] else { merged[key] = incoming; continue }
      let oldStamp = timestamp((current as? [String: Any])?["updatedAt"])
      let newStamp = timestamp((incoming as? [String: Any])?["updatedAt"])
      if newStamp > oldStamp { merged[key] = incoming }
      else if newStamp == oldStamp {
        let oldBytes = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys, .fragmentsAllowed])
        let newBytes = try JSONSerialization.data(withJSONObject: incoming, options: [.sortedKeys, .fragmentsAllowed])
        if oldBytes.lexicographicallyPrecedes(newBytes) { merged[key] = incoming }
      }
    }
    return merged
  }

  static func decodeDocument(_ bytes: Data, filename: String?) throws -> [String: Any] {
    guard bytes.count <= LibraryMetadataStore.maxDocumentBytes else { throw StoreError.documentTooLarge }
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw StoreError.invalidDocument
    }
    var identities = Set<Identity>()
    for key in object.keys where key.hasPrefix("game:") || key.hasPrefix("sha256:") {
      for field in ["title", "cover", "tags"] where key.hasSuffix(":" + field) {
        identities.insert(Identity(String(key.dropLast(field.count + 1))))
      }
    }
    if let filename, !LibraryMetadataStore.isValidShardFilename(filename) { throw StoreError.identityMismatch }
    for identity in identities {
      if let filename, identity.fileName != filename { throw StoreError.identityMismatch }
      _ = try project(object, for: identity, includeCover: false)
    }
    return object
  }

  static func project(_ object: [String: Any], for identity: Identity, includeCover: Bool = true) throws -> Draft {
    func value(_ field: String) throws -> Any? {
      guard let raw = object[identity.rawValue + ":" + field] else { return nil }
      guard let record = raw as? [String: Any], let value = record["value"] else {
        throw StoreError.invalidRecord(field)
      }
      return value is NSNull ? nil : value
    }
    var result = Draft()
    if let title = try value("title") {
      guard let title = title as? String else { throw StoreError.invalidRecord("title") }
      result.title = title
    }
    if let cover = try value("cover") {
      // Bound the encoded form before allocating decoded bytes from remote JSON.
      guard let encoded = cover as? String, validCoverEncoding(encoded) else {
        throw StoreError.invalidRecord("cover")
      }
      if includeCover {
        guard let data = Data(base64Encoded: encoded) else { throw StoreError.invalidRecord("cover") }
        result.coverData = data
      }
    }
    if let tags = try value("tags") {
      guard let tags = tags as? [String] else { throw StoreError.invalidRecord("tags") }
      result.tags = tags
    }
    return try normalized(result)
  }

  /// Validate remote base64 without allocating a decoded cover during title/tag
  /// scans. Padding determines the exact byte count, including the final quartet.
  private static func validCoverEncoding(_ encoded: String) -> Bool {
    let bytes = encoded.utf8
    let count = bytes.count
    guard count <= ((LibraryMetadataStore.maxCoverBytes + 2) / 3) * 4, count % 4 == 0 else { return false }
    let padding = bytes.last == 61 ? (bytes.dropLast().last == 61 ? 2 : 1) : 0
    guard count / 4 * 3 - padding <= LibraryMetadataStore.maxCoverBytes else { return false }
    return bytes.dropLast(padding).allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47
    }
  }

  static func normalized(_ draft: Draft) throws -> Draft {
    let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (title?.count ?? 0) <= LibraryMetadataStore.maxTitleLength else { throw StoreError.titleTooLong }
    guard (draft.coverData?.count ?? 0) <= LibraryMetadataStore.maxCoverBytes else { throw StoreError.coverTooLarge }
    var seen = Set<String>()
    var tags: [String] = []
    for raw in draft.tags {
      let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard tag.count <= LibraryMetadataStore.maxTagLength else { throw StoreError.tagTooLong }
      if !tag.isEmpty, seen.insert(tag.lowercased()).inserted { tags.append(tag) }
    }
    guard tags.count <= LibraryMetadataStore.maxTagCount else { throw StoreError.tooManyTags }
    return Draft(title: title?.isEmpty == false ? title : nil, coverData: draft.coverData, tags: tags)
  }

  /// Same timestamp forms understood by the pinned opaque-record merger. New
  /// writes use numeric reference-date seconds, preserving subsecond ordering.
  static func timestamp(_ value: Any?) -> Double {
    if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
    if let string = value as? String {
      if let date = ISO8601DateFormatter().date(from: string) { return date.timeIntervalSinceReferenceDate }
      if let number = Double(string), number.isFinite { return number }
    }
    return -.infinity
  }
}

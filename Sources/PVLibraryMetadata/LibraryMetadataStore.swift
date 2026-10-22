// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

/// App-owned custom library fields. This file is separate from emulator profiles,
/// so resetting per-game emulation settings cannot remove library edits.
// All mutable state and writers are accessed through the serialized file gate.
public final class LibraryMetadataStore: @unchecked Sendable {
  public struct Identity: Hashable, Sendable {
    public let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    public var fileName: String {
      SHA256.hash(data: Data(rawValue.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    public static func game(gameID: String, discNumber: Int, revision: Int) -> Identity? {
      let id = gameID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      guard !id.isEmpty, id != "<UNKNOWN>", !id.hasPrefix("ID-"),
            discNumber >= 0, revision >= 0 else { return nil }
      return Identity("game:" + Data(id.utf8).base64EncodedString() + ":\(discNumber):\(revision)")
    }

    /// Accepts only exact canonical strings emitted by the identity constructors.
    public static func parseCanonical(_ raw: String) -> Identity? {
      let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
      let identity: Identity?
      if parts.count == 2, parts[0] == "sha256" {
        identity = contentHash(String(parts[1]))
      } else if parts.count == 4, parts[0] == "game",
                let data = Data(base64Encoded: String(parts[1])),
                let gameID = String(data: data, encoding: .utf8),
                let disc = Int(parts[2]), let revision = Int(parts[3]) {
        identity = game(gameID: gameID, discNumber: disc, revision: revision)
      } else { return nil }
      guard let identity, identity.rawValue == raw else { return nil }
      return identity
    }

    /// Unknown/homebrew entries require a content identity supplied by the caller.
    /// Display names and filesystem paths must never alias unrelated homebrew.
    public static func contentHash(_ sha256: String) -> Identity? {
      let normalized = sha256.lowercased()
      guard normalized.utf8.count == 64,
        normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
      return Identity("sha256:" + normalized)
    }
  }

  public struct Draft: Equatable, Sendable {
    public var title: String?
    public var coverData: Data?
    public var tags: [String]
    public init(title: String? = nil, coverData: Data? = nil, tags: [String] = []) {
      self.title = title; self.coverData = coverData; self.tags = tags
    }
  }

  /// The gate must serialize calls and synchronously execute each operation once.
  /// The app injects the
  /// same short lock used by its sync scanner; no lock spans a network operation.
  public typealias FileAccess = (_ operation: () throws -> Void) throws -> Void
  public typealias Writer = (_ data: Data, _ url: URL) throws -> Void
  public static let maxTitleLength = 200
  public static let maxTagCount = 32
  public static let maxTagLength = 40
  public static let maxCoverBytes = 256 * 1024
  public static let maxDocumentBytes = 1024 * 1024

  public enum StoreError: LocalizedError {
    case invalidDocument, invalidRecord(String), invalidTransaction, identityMismatch
    case titleTooLong, tooManyTags, tagTooLong, coverTooLarge, documentTooLarge, invalidTimestamp
    case cacheCapacity, recoveryUnavailable

    public var errorDescription: String? {
      switch self {
      case .invalidDocument: return "Library metadata is not a valid JSON object."
      case .invalidRecord(let field): return "Invalid library metadata field: \(field)."
      case .identityMismatch: return "Library metadata identity does not match its shard filename."
      case .invalidTransaction: return "Library metadata transaction did not execute."
      case .titleTooLong: return "Custom titles must be 200 characters or fewer."
      case .tooManyTags: return "A game can have at most 32 classification tags."
      case .tagTooLong: return "Classification tags must be 40 characters or fewer."
      case .coverTooLarge: return "Custom covers must be 256 KiB or smaller."
      case .documentTooLarge: return "Library metadata exceeds the 1 MiB per-game document limit."
      case .invalidTimestamp: return "Library metadata edit has an invalid timestamp."
      case .cacheCapacity: return "Library metadata cannot fit in its memory cache."
      case .recoveryUnavailable: return "Previously loaded library metadata is unavailable. Restore its local recovery copy before editing."
      }
    }
  }

  public struct Summary: Equatable, Sendable {
    public let title: String?
    public let tags: [String]
    public init(title: String?, tags: [String]) {
      self.title = title; self.tags = tags
    }
  }

  public struct CacheStatistics {
    public let recordCount: Int
    public let retainedBytes: Int
    public let decodedCoverBytes: Int
    public let summaryCount: Int
    public let summaryBytes: Int
    public init(recordCount: Int, retainedBytes: Int, decodedCoverBytes: Int, summaryCount: Int, summaryBytes: Int) {
      self.recordCount = recordCount; self.retainedBytes = retainedBytes
      self.decodedCoverBytes = decodedCoverBytes; self.summaryCount = summaryCount; self.summaryBytes = summaryBytes
    }
  }

  private struct CachedRecord {
    let bytes: Data
    let summary: Summary
    var projection: Draft?
    var used: UInt64 = 0
    func cost(for identity: Identity) -> Int {
      let coverBytes: Int = projection?.coverData?.count ?? 0
      let titleBytes: Int = (summary.title?.utf8.count ?? 0) * 2
      let tagBytes: Int = summary.tags.reduce(0) { $0 + $1.utf8.count * 2 + 32 }
      let identityBytes: Int = identity.rawValue.utf8.count * 2
      var total: Int = bytes.count + coverBytes
      total += titleBytes
      total += tagBytes
      total += identityBytes
      return total + 1024
    }
  }

  private struct CachedSummary {
    let value: Summary
    var used: UInt64
    func cost(for identity: Identity) -> Int {
      let titleBytes: Int = (value.title?.utf8.count ?? 0) * 2
      let tagBytes: Int = value.tags.reduce(0) { $0 + $1.utf8.count * 2 + 32 }
      let identityBytes: Int = identity.rawValue.utf8.count * 2
      var total: Int = titleBytes + tagBytes
      total += identityBytes
      return total + 512
    }
  }

  private let directoryURL: URL
  private let recoveryDirectoryURL: URL
  private let fileAccess: FileAccess
  private let write: Writer
  private let writeRecovery: Writer
  private let cacheByteLimit: Int
  private let cacheCountLimit: Int
  private var records: [Identity: CachedRecord] = [:]
  private var summaries: [Identity: CachedSummary] = [:]
  private var summaryBytesUsed = 0
  private let summaryByteLimit: Int
  private let summaryCountLimit: Int
  // Compact receipts distinguish an evicted/purged shard from an unseen game.
  // A missing shard is never interpreted as a timestamped clear.
  private var seen = Set<String>()
  private var stale = Set<Identity>()
  private var clock: UInt64 = 0

  public init(directoryURL: URL, withFileAccess: FileAccess? = nil,
       write: @escaping Writer = { try $0.write(to: $1, options: .atomic) },
       recoveryDirectoryURL: URL? = nil, cacheByteLimit: Int = 16 * 1024 * 1024,
       cacheCountLimit: Int = 64, summaryByteLimit: Int = 4 * 1024 * 1024,
       summaryCountLimit: Int = 8192,
       writeRecovery: @escaping Writer = { try $0.write(to: $1, options: .atomic) }) throws {
    self.directoryURL = directoryURL
    // Production: Profiles/LibraryMetadataRecovery, outside the sync allowlist.
    self.recoveryDirectoryURL = recoveryDirectoryURL ?? directoryURL.deletingLastPathComponent()
      .appendingPathComponent(directoryURL.lastPathComponent + "Recovery", isDirectory: true)
    let lock = NSRecursiveLock()
    self.fileAccess = withFileAccess ?? { operation in
      lock.lock(); defer { lock.unlock() }; try operation()
    }
    self.write = write
    self.writeRecovery = writeRecovery
    self.cacheByteLimit = cacheByteLimit
    self.cacheCountLimit = cacheCountLimit
    self.summaryByteLimit = summaryByteLimit
    self.summaryCountLimit = summaryCountLimit
  }

  /// Sorting/searching need no retained decoded cover. Full records remain bounded.
  public func summary(for identity: Identity) throws -> Summary {
    try withAccess {
      if let cached = summaries[identity], !stale.contains(identity) {
        if records[identity] != nil { touch(identity) }
        clock &+= 1
        summaries[identity]?.used = clock
        return cached.value
      }
      try refreshIfNeeded(identity)
      touch(identity)
      let summary = records[identity]!.summary
      cacheSummary(summary, for: identity)
      return summary
    }
  }

  /// A failed refresh throws once, retaining the last validated projection, even
  /// when that record had to be recovered after eviction or a cache purge.
  public func draft(for identity: Identity) throws -> Draft {
    try withAccess {
      try refreshIfNeeded(identity)
      var entry = records[identity]!
      if let projection = entry.projection { touch(identity); return projection }
      let projection = try LibraryMetadataDocument.project(LibraryMetadataDocument.decodeDocument(entry.bytes, filename: identity.fileName), for: identity)
      entry.projection = projection
      let victims = try prepareAdmission(entry, for: identity)
      adopt(entry, for: identity, evicting: victims)
      return projection
    }
  }

  public func cacheStatistics() throws -> CacheStatistics {
    try withAccess {
      CacheStatistics(recordCount: records.count,
        retainedBytes: records.reduce(0) { $0 + $1.value.cost(for: $1.key) },
        decodedCoverBytes: records.values.reduce(0) { $0 + ($1.projection?.coverData?.count ?? 0) },
        summaryCount: summaries.count,
        summaryBytes: summaryBytesUsed)
    }
  }

  private func touch(_ identity: Identity) {
    clock &+= 1
    records[identity]?.used = clock
  }

  /// Lightweight sort/search hits survive full-record eviction. This cache has
  /// its own byte/count limits and never owns encoded or decoded cover bytes.
  private func cacheSummary(_ value: Summary, for identity: Identity) {
    clock &+= 1
    let entry = CachedSummary(value: value, used: clock)
    if let previous = summaries.removeValue(forKey: identity) { summaryBytesUsed -= previous.cost(for: identity) }
    let cost = entry.cost(for: identity)
    guard summaryCountLimit > 0, cost <= summaryByteLimit else { return }
    if summaries.count >= summaryCountLimit || summaryBytesUsed + cost > summaryByteLimit {
      for (key, cached) in summaries.sorted(by: { $0.value.used < $1.value.used }) {
        if summaries.count < summaryCountLimit, summaryBytesUsed + cost <= summaryByteLimit { break }
        summaryBytesUsed -= cached.cost(for: key)
        summaries.removeValue(forKey: key)
        if records[key] == nil { stale.remove(key) }
      }
    }
    summaries[identity] = entry
    summaryBytesUsed += cost
  }

  private func makeRecord(_ bytes: Data, for identity: Identity, projection: Draft? = nil) throws -> CachedRecord {
    let object = try LibraryMetadataDocument.decodeDocument(bytes, filename: identity.fileName)
    let fields = try LibraryMetadataDocument.project(object, for: identity, includeCover: false)
    return CachedRecord(bytes: bytes, summary: Summary(title: fields.title, tags: fields.tags), projection: projection)
  }

  /// All recovery writes complete before any victim leaves memory. A failure
  /// leaves the authoritative cache intact and is surfaced through the caller.
  private func prepareAdmission(_ incoming: CachedRecord, for identity: Identity) throws -> [Identity] {
    let cost = incoming.cost(for: identity)
    guard cacheCountLimit > 0, cost <= cacheByteLimit else { throw StoreError.cacheCapacity }
    var total = cost
    var count = 1
    var victims: [Identity] = []
    for (key, entry) in records.filter({ $0.key != identity }).sorted(by: { $0.value.used > $1.value.used }) {
      let size = entry.cost(for: key)
      if count < cacheCountLimit, total + size <= cacheByteLimit {
        total += size; count += 1
      } else { victims.append(key) }
    }
    for key in victims {
      let entry = records[key]!
      // Never snapshot an uncommitted draft; only validated durable raw bytes.
      if entry.bytes != Data("{}".utf8) {
        let bytes = try recoverySnapshot(entry.bytes, for: key)
        try FileManager.default.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
        try writeRecovery(bytes, recoveryDirectoryURL.appendingPathComponent(key.fileName))
      }
    }
    return victims
  }

  /// Another store may have saved since this cache entry was loaded. Converge
  /// complete validated records using the sync engine's opaque per-field LWW
  /// contract, including explicit null tombstones and canonical-byte tie breaks.
  private func recoverySnapshot(_ cached: Data, for identity: Identity) throws -> Data {
    var merged = try LibraryMetadataDocument.decodeDocument(cached, filename: identity.fileName)
    let sources = [try? boundedRead(directoryURL.appendingPathComponent(identity.fileName)),
                   try? recoveryBytes(for: identity)]
    for source in sources {
      guard let source,
            let object = try? LibraryMetadataDocument.decodeDocument(source, filename: identity.fileName) else { continue }
      merged = try LibraryMetadataDocument.mergeObjects(local: merged, remote: object)
    }
    let result = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    try Self.validateDocument(data: result, filename: identity.fileName)
    return result
  }

  private func adopt(_ entry: CachedRecord, for identity: Identity, evicting victims: [Identity]) {
    for victim in victims {
      records.removeValue(forKey: victim)
      if summaries[victim] == nil { stale.remove(victim) }
    }
    records[identity] = entry
    if entry.bytes != Data("{}".utf8) { seen.insert(identity.fileName) }
    stale.remove(identity)
    touch(identity)
    cacheSummary(entry.summary, for: identity)
  }

  private func refreshIfNeeded(_ identity: Identity) throws {
    if records[identity] != nil, !stale.contains(identity) { return }
    do {
      let entry = try makeRecord(readBytes(for: identity), for: identity)
      let victims = try prepareAdmission(entry, for: identity)
      adopt(entry, for: identity, evicting: victims)
    } catch {
      // Malformed primary bytes remain untouched. Recover a prior valid record
      // for the next read, but still report this refresh failure to the caller.
      if records[identity] != nil { stale.remove(identity) }
      else if let bytes = try? recoveryBytes(for: identity),
              let entry = try? makeRecord(bytes, for: identity),
              let victims = try? prepareAdmission(entry, for: identity) {
        adopt(entry, for: identity, evicting: victims)
      }
      // A title/tag projection can survive even if its full recovery record is
      // unavailable. Report the refresh error once, retain that valid summary.
      if summaries[identity] != nil { stale.remove(identity) }
      throw error
    }
  }

  /// Only fields changed against the sheet's captured baseline are edited. Reading
  /// latest disk bytes under the shared gate preserves concurrent unrelated edits.
  /// Blank title, nil cover and an empty tag list mean clear, with retained stamps.
  @discardableResult
  public func commit(_ draft: Draft, baseline: Draft, for identity: Identity, at date: Date = Date()) throws -> Draft {
    let edited = try LibraryMetadataDocument.normalized(draft)
    let baseline = try LibraryMetadataDocument.normalized(baseline)
    let now = date.timeIntervalSinceReferenceDate
    guard now.isFinite else { throw StoreError.invalidTimestamp }
    return try withAccess {
      var candidate = try LibraryMetadataDocument.decodeDocument(readBytes(for: identity), filename: identity.fileName)
      let fileURL = directoryURL.appendingPathComponent(identity.fileName)
      // Reject a malformed current record rather than replacing evidence of it.
      _ = try LibraryMetadataDocument.project(candidate, for: identity)
      var changed = false
      func update(_ field: String, value: Any) throws {
        let key = identity.rawValue + ":" + field
        var record = candidate[key] as? [String: Any] ?? [:]
        let previous = LibraryMetadataDocument.timestamp(record["updatedAt"])
        let stamp = max(now, previous.isFinite ? previous.nextUp : now)
        guard stamp.isFinite else { throw StoreError.invalidTimestamp }
        record["updatedAt"] = stamp
        record["value"] = value
        candidate[key] = record
        changed = true
      }
      if edited.title != baseline.title {
        try update("title", value: edited.title.map { $0 as Any } ?? NSNull())
      }
      if edited.coverData != baseline.coverData {
        try update("cover", value: edited.coverData.map { $0.base64EncodedString() as Any } ?? NSNull())
      }
      if edited.tags != baseline.tags {
        try update("tags", value: edited.tags.isEmpty ? NSNull() : edited.tags)
      }
      let projection = try LibraryMetadataDocument.project(candidate, for: identity)
      let bytes = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
      let entry = try makeRecord(bytes, for: identity, projection: projection)
      // Snapshot eviction victims before committing: a recovery failure cannot
      // report a failed Save after the user's primary file already changed.
      let victims = try prepareAdmission(entry, for: identity)
      if changed {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(bytes, fileURL)
      }
      // Publish only after durable success. Failure keeps the previous valid cache.
      adopt(entry, for: identity, evicting: victims)
      return projection
    }
  }

  /// Export authoritative committed bytes under the shared file gate, preserving
  /// opaque fields and the exact encoding of an existing primary or recovery copy.
  public func exportDocument(for identity: Identity) throws -> Data {
    try withAccess {
      let bytes = try readBytes(for: identity)
      try LibraryMetadataDocument.validate(data: bytes, filename: identity.fileName)
      return bytes
    }
  }

  /// Admit remote records and durably merge them with the latest authority in
  /// one synchronous file transaction. Received timestamps are never restamped.
  public func mergeDocument(_ data: Data, for identity: Identity) throws -> Data {
    try withAccess {
      try LibraryMetadataDocument.validateIncoming(data: data, for: identity)
      let current = try readBytes(for: identity)
      let bytes = try LibraryMetadataDocument.merge(local: current, remote: data, for: identity)
      let entry = try makeRecord(bytes, for: identity)
      let victims = try prepareAdmission(entry, for: identity)
      if bytes != current {
        let fileURL = directoryURL.appendingPathComponent(identity.fileName)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try write(bytes, fileURL)
      }
      adopt(entry, for: identity, evicting: victims)
      return bytes
    }
  }

  public func reload() throws {
    try withAccess { stale.formUnion(records.keys); stale.formUnion(summaries.keys) }
  }

  private func withAccess<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    try fileAccess { result = Result { try body() } }
    guard let result else { throw StoreError.invalidTransaction }
    return try result.get()
  }

  private func boundedRead(_ url: URL) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let size = attributes[.size] as? NSNumber, size.int64Value > Self.maxDocumentBytes {
      throw StoreError.documentTooLarge
    }
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= Self.maxDocumentBytes else { throw StoreError.documentTooLarge }
    return bytes
  }

  private func recoveryBytes(for identity: Identity) throws -> Data {
    let bytes = try boundedRead(recoveryDirectoryURL.appendingPathComponent(identity.fileName))
    try Self.validateDocument(data: bytes, filename: identity.fileName)
    return bytes
  }

  private func readBytes(for identity: Identity) throws -> Data {
    do { return try boundedRead(directoryURL.appendingPathComponent(identity.fileName)) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      if let entry = records[identity] { return entry.bytes }
      do { return try recoveryBytes(for: identity) }
      catch let recoveryError as CocoaError where recoveryError.code == .fileReadNoSuchFile {
        if seen.contains(identity.fileName) { throw StoreError.recoveryUnavailable }
        return Data("{}".utf8)
      }
    }
  }

  /// Validate untrusted cloud bytes before the sync scanner promotes them. Unknown
  /// record/field keys remain opaque so a newer schema can round-trip safely.
  public static func validateDocument(data: Data, filename: String? = nil) throws {
    try LibraryMetadataDocument.validate(data: data, filename: filename)
  }

  public static func isValidShardFilename(_ filename: String) -> Bool {
    guard filename.hasSuffix(".json") else { return false }
    let hash = filename.dropLast(5)
    return hash.utf8.count == 64 && hash.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

}

// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Serializes metadata commits with grant revocation. This supplies linearization,
/// not authentication or a persistent enabled setting; check the actual peer grant
/// before issuing a permit.
///
/// Lock order is grant-gate -> store-file-gate. Never acquire this gate while
/// holding the store file gate, call recursively into this gate, or perform
/// network/async work inside an operation. Keep operations short and synchronous.
// All mutable state and operation execution are protected by the nonrecursive lock.
public final class LibraryMetadataCommitGate: @unchecked Sendable {
  /// An opaque capability bound to one gate and one generation.
  public struct Permit: Sendable {
    fileprivate let owner: UUID
    fileprivate let generation: UUID
  }

  public enum GateError: Error, Sendable {
    case invalidPermit
  }

  private let lock = NSLock()
  private let owner = UUID()
  private var generation = UUID()

  public init() {}

  /// Issues a permit for the current generation after the caller checks the grant.
  public func issue() -> Permit {
    lock.lock()
    defer { lock.unlock() }
    return Permit(owner: owner, generation: generation)
  }

  /// Revokes all previously issued permits. Already-admitted operations finish
  /// before this returns; subsequent admissions reject those old permits.
  public func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    generation = UUID()
  }

  /// Runs the operation exactly once under the lock if the permit is current.
  /// Throws `GateError.invalidPermit` without entering an invalid operation.
  public func withPermit<T>(_ permit: Permit, operation: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard permit.owner == owner, permit.generation == generation else {
      throw GateError.invalidPermit
    }
    return try operation()
  }
}

// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The CloudKit record schema's field names and the default timings.
///
/// The app-specific identifiers (container, zone, record type) are in
/// `CloudSyncConfiguration`, which each app supplies.
public enum CloudSyncConstants {

    /// Field names on `recordType`. Centralised because a typo in one of these
    /// is a silent "record never round-trips" bug, not a compile error.
    public enum Field {
        public static let fileName = "fileName"
        public static let fileData = "fileData"
        public static let lastModified = "lastModified"
        public static let checksum = "checksum"
        public static let fileType = "fileType"
        public static let fileSize = "fileSize"
        public static let deviceIdentifier = "deviceIdentifier"
        public static let appVersion = "appVersion"
        /// `Int64` 1 on a tombstone, absent or 0 on a live file. A tombstone
        /// keeps `fileName`, `checksum` (of the deleted content), `fileType`
        /// and `deviceIdentifier`, and has no `fileData`.
        public static let deleted = "deleted"
        public static let deletedAt = "deletedAt"
    }

    /// How long a tombstone stays on the remote before any device may remove
    /// it. A device offline longer than this re-uploads the file.
    public static let tombstoneRetention: TimeInterval = 90 * 24 * 60 * 60

    /// How long a locally trashed file is kept before the trash purges it.
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Default for how often the background timer fires a sync (30 minutes).
    public static let backgroundSyncInterval: TimeInterval = 30 * 60

    /// Filesystem-watcher debounce.
    public static let watcherDebounceInterval: TimeInterval = 0.5

    /// Two modification times within this many seconds are treated as "the same
    /// version" and skipped, so a round-tripped file does not churn.
    public static let modificationTimeTolerance: TimeInterval = 2.0
}

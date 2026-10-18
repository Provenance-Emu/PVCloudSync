import Foundation

/// The per-app settings for CloudKit sync. Each app builds one and passes it to
/// `CloudKitSyncProvider` and `CloudKitAvailability`; nothing app-specific is
/// baked into the package.
///
/// ```swift
/// let cloud = CloudSyncConfiguration(
///     containerIdentifier: "iCloud.com.joemattiello.iCube",
///     zoneName: "iCubeUserData",
///     recordType: "iCubeUserFile"
/// )
/// ```
///
/// Never change `zoneName` or `recordType` for a shipped app: existing records
/// live under them.
public struct CloudSyncConfiguration: Sendable, Equatable {
    /// The app's CloudKit container.
    public var containerIdentifier: String

    /// Custom record zone in the **private** database. A custom zone (rather
    /// than the default zone) is what makes `CKFetchRecordZoneChangesOperation`
    /// usable, which lets the provider enumerate every record without needing
    /// `recordName` marked Queryable in the CloudKit schema.
    public var zoneName: String

    /// The one and only record type. A single type is enough: the category
    /// lives in a field, not in the schema, so adding a `SyncableFileType` case
    /// never requires a CloudKit schema migration.
    public var recordType: String

    /// Whether the container exists and every shipping App ID and entitlements
    /// file has it. While `false`, CloudKit is never touched: on a store build
    /// with no embedded profile, `CKContainer.init` for an unprovisioned
    /// container traps, and the profile probe can't catch that case.
    public var containerIsProvisioned: Bool

    /// How long a tombstone stays on the remote before any device may remove it.
    /// A device offline longer than this re-uploads the file.
    public var tombstoneRetention: TimeInterval
    /// How long a locally trashed file is kept before the trash purges it.
    public var trashRetention: TimeInterval
    /// How often the background timer fires a sync.
    public var backgroundSyncInterval: TimeInterval
    /// Filesystem-watcher debounce.
    public var watcherDebounceInterval: TimeInterval
    /// Two modification times within this many seconds are "the same version".
    public var modificationTimeTolerance: TimeInterval

    public init(
        containerIdentifier: String,
        zoneName: String,
        recordType: String,
        containerIsProvisioned: Bool = true,
        tombstoneRetention: TimeInterval = CloudSyncConstants.tombstoneRetention,
        trashRetention: TimeInterval = CloudSyncConstants.trashRetention,
        backgroundSyncInterval: TimeInterval = CloudSyncConstants.backgroundSyncInterval,
        watcherDebounceInterval: TimeInterval = CloudSyncConstants.watcherDebounceInterval,
        modificationTimeTolerance: TimeInterval = CloudSyncConstants.modificationTimeTolerance
    ) {
        self.containerIdentifier = containerIdentifier
        self.zoneName = zoneName
        self.recordType = recordType
        self.containerIsProvisioned = containerIsProvisioned
        self.tombstoneRetention = tombstoneRetention
        self.trashRetention = trashRetention
        self.backgroundSyncInterval = backgroundSyncInterval
        self.watcherDebounceInterval = watcherDebounceInterval
        self.modificationTimeTolerance = modificationTimeTolerance
    }
}

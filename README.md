# PVCloudSync

CloudKit sync of an emulator app's user files (saves, states, settings): scanning,
planning, conflict resolution, tombstones, a local trash, retry and lifecycle policy, and a
CloudKit provider. Classification comes from
[PVSyncRules](https://github.com/Provenance-Emu/PVSyncRules).

```swift
.package(url: "https://github.com/Provenance-Emu/PVCloudSync.git", .upToNextMajor(from: "1.0.0"))
```

Each app supplies its CloudKit identity:

```swift
let cloud = CloudSyncConfiguration(
    containerIdentifier: "iCloud.com.example.app",
    zoneName: "AppUserData",
    recordType: "AppUserFile"
)
if let provider = CloudKitSyncProvider(configuration: cloud, deviceIdentifier: deviceID) { … }
let reason = CloudKitAvailability.buildLevelUnavailableReason(for: cloud)
```

Never change `zoneName` or `recordType` for a shipped app; its records live under them.

Extracted on 2026-10-17 from iCube's `Source/iOS/PVCloudSync` (Provenance-Emu/iCube
`093cefdccc`), with history.

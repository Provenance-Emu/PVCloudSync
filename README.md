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


## Custom library metadata

The additive `PVLibraryMetadata` product stores custom titles, covers and tags
independently of CloudKit, UIKit and Realm. Add that product to the consuming
target and `import PVLibraryMetadata`. It uses the same iOS/tvOS 17 and macOS 14
minimums as the existing product.

`LibraryMetadataStore` retains iCube's canonical per-game shard bytes and its
injected synchronous file gate. `LibraryMetadataDocument` provides the pure
per-record merge; known incoming fields require valid timestamps, while local
historical decoding preserves compatibility. Export returns committed bytes and
remote merge preserves incoming timestamps, unknown fields and null clears.

`LibraryMetadataCommitGate` serializes short synchronous commits with permission
revocation. Check the actual peer/account grant before issuing a permit, acquire
the permission gate before the store file gate, and keep network work outside
both locks. The gate does not authenticate a peer or grant access itself.

`LibraryEditsWireCodec` bounds manifests and document envelopes. Exchange evidence
is a remote claim: applications must independently verify a local disc identity
or a successfully imported content hash before applying edits. Pairing, ROM
access and metadata sharing require their own application permissions. This
package does not discover peers, transfer ROMs or enable synchronization.

Run all package tests with `swift test --jobs 2`.

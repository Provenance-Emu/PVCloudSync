// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Non-trapping "can this build construct a `CKContainer` at all?" check.
///
/// `CKContainer(identifier:)` does not fail gracefully — it **hard-traps**
/// (`EXC_BREAKPOINT` / `SIGTRAP`) rather than returning nil or throwing, so there
/// is nothing to `catch` and the only safe move is not to call it. Ported from
/// iFly, where this crashed the app at launch on the Simulator; the reasoning
/// below is Apple-generic, not Flycast-specific.
///
/// What iFly verified, and why the obvious fixes are ruled out:
/// - A simulator build is ad-hoc signed; `codesign -d --entitlements` reports an
///   empty dict, but the linker-embedded `__TEXT,__entitlements` section still
///   lists the container. The two sources disagree and which one the runtime
///   consults is not established — so reading `__TEXT,__entitlements` (the
///   approach Provenance uses) answers "entitled" and traps anyway.
/// - `SecTaskCreateFromSelf` is macOS-SDK-only: there is no public iOS API to
///   read our own signed entitlements.
/// - `FileManager.ubiquityIdentityToken` is not a proxy for this. It reflects the
///   *ubiquity* entitlement plus iCloud-Drive account state, so a device with
///   iCloud Drive off but a working CloudKit account reports nil. A false
///   negative on device is worse than the bug being fixed.
///
/// Hence: a hard simulator gate, plus a provisioning-profile probe on device.
///
/// ## The provisioning gate (`CloudSyncConfiguration.containerIsProvisioned`)
///
/// iFly treats "no `embedded.mobileprovision`" as entitled, on the reasoning that
/// App Store validation already enforced the entitlement. **That reasoning does
/// not hold for an app whose container is not provisioned yet** (iCube until
/// 2026-10-14), where none of the entitlements files request it — so an App Store / TestFlight
/// build would take that branch, call `CKContainer.init`, and trap. Everything
/// here is therefore gated behind the configuration's `containerIsProvisioned`.
public enum CloudKitAvailability {

    /// Why CloudKit cannot be used with `configuration` on this build, or `nil`
    /// if it can. The provisioning-profile probe below turns CloudKit off on a
    /// build whose profile lacks the container (re-signed sideloads), so a
    /// provisioned configuration never traps either.
    public static func buildLevelUnavailableReason(for configuration: CloudSyncConfiguration) -> SyncUnavailableReason? {
        guard configuration.containerIsProvisioned else { return .containerNotProvisioned }
        guard isUsable(forContainerIdentifier: configuration.containerIdentifier) else {
            return .entitlementMissing
        }
        return nil
    }

    /// False when this build cannot construct the app's container without
    /// trapping. Callers must treat false as "the iCloud feature is quietly
    /// off", never as an error to surface.
    public static func isUsable(_ configuration: CloudSyncConfiguration) -> Bool {
        buildLevelUnavailableReason(for: configuration) == nil
    }

    /// Whether `identifier` may be passed to `CKContainer(identifier:)` without
    /// trapping on this build. Doesn't know whether the container is
    /// provisioned; `buildLevelUnavailableReason(for:)` checks that first.
    public static func isUsable(forContainerIdentifier identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        #if targetEnvironment(simulator)
        // Covers the tvOS Simulator too. CloudKit is unusable there in practice
        // anyway — re-signing a simulator build strips iCloud entitlements — so
        // nothing real is given up, and the device path stays bit-for-bit
        // unchanged.
        return false
        #else
        switch provisioningCloudKitContainers {
        case .none:
            // No embedded profile (App Store): store validation enforced the
            // entitlement. Callers check `containerIsProvisioned` before this.
            return true
        case .some(let containers):
            return containers.contains(trimmed)
        }
        #endif
    }

    #if canImport(CloudKit)
    /// Soft-fail factory: never calls `CKContainer(identifier:)` on a build where
    /// it would trap.
    public static func makeContainer(for configuration: CloudSyncConfiguration) -> CKContainer? {
        guard isUsable(configuration) else { return nil }
        return CKContainer(identifier: configuration.containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    #endif

    // MARK: - Provisioning-profile entitlement probe (device only)

    /// CloudKit container identifiers from `embedded.mobileprovision`, or `nil`
    /// when no profile is embedded (App Store) or the blob cannot be parsed.
    private static let provisioningCloudKitContainers: [String]? = {
        #if targetEnvironment(simulator)
        return nil
        #else
        return cloudKitContainersFromProvisioningProfile()
        #endif
    }()

    /// Parses the `embedded.mobileprovision` PKCS#7 blob for
    /// `com.apple.developer.icloud-container-identifiers`.
    private static func cloudKitContainersFromProvisioningProfile() -> [String]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        // A mobileprovision is a PKCS#7 signed blob with a plain-text plist inside.
        guard let raw = String(data: data, encoding: .ascii),
              let plistStart = raw.range(of: "<?xml"),
              let plistEnd = raw.range(of: "</plist>") else {
            return nil
        }
        // `plistEnd.upperBound` already sits just past `</plist>`.
        let plistSlice = String(raw[plistStart.lowerBound ..< plistEnd.upperBound])
        guard let plistData = plistSlice.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return nil
        }
        if let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] {
            return containers
        }
        // Profile present but the key is missing → not entitled.
        return []
    }
}

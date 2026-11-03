import Foundation
import XCTest
@testable import Proofline

/// Keeps `PrivacyInfo.xcprivacy` accurate: no tracking, the declared data types, and no
/// required-reason APIs anywhere in the sources (so the empty `NSPrivacyAccessedAPITypes` is true).
final class PrivacyManifestTests: XCTestCase {
    static let sourcesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Proofline")

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.sourcesURL.appendingPathComponent("Resources/PrivacyInfo.xcprivacy"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testNoTrackingAndNoTrackingDomains() throws {
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
    }

    func testDeclaredDataTypesAreLinkedAndNotUsedForTracking() throws {
        let types = try XCTUnwrap(try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let names = Set(types.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(names, [
            "NSPrivacyCollectedDataTypePurchaseHistory",
            "NSPrivacyCollectedDataTypeUserID",
            // The random install id: one install on one device, so a device-level ID.
            "NSPrivacyCollectedDataTypeDeviceID",
            "NSPrivacyCollectedDataTypeProductInteraction",
        ])
        for t in types {
            XCTAssertEqual(t["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(t["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            let purposes = try XCTUnwrap(t["NSPrivacyCollectedDataTypePurposes"] as? [String])
            XCTAssertFalse(purposes.isEmpty)
            XCTAssertFalse(purposes.contains("NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising"))
        }
    }

    func testNoRequiredReasonAPIsAreUsed() throws {
        XCTAssertEqual((try manifest()["NSPrivacyAccessedAPITypes"] as? [Any])?.count, 0)
        // Required-reason API categories (file timestamp, boot time, disk space, active keyboards,
        // user defaults) and identifiers the SDK must never touch.
        let forbidden = [
            "UserDefaults", "NSUserDefaults",
            "creationDate", "modificationDate", "contentModificationDate", "creationDateKey",
            "fileModificationDate", "attributesOfItem", "getattrlist", "stat(", "fstat(",
            "systemUptime", "mach_absolute_time", "ContinuousClock", "SuspendingClock",
            "volumeAvailableCapacity", "systemFreeSize", "systemSize", "statfs",
            "activeInputModes",
            "ASIdentifierManager", "advertisingIdentifier", "identifierForVendor", "ATTrackingManager",
            "UIDevice.current.name", "sysctl",
        ]
        let files = try FileManager.default.contentsOfDirectory(at: Self.sourcesURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for symbol in forbidden {
                XCTAssertFalse(source.contains(symbol), "\(file.lastPathComponent) uses \(symbol)")
            }
        }
    }

    func testManifestIsBundledAsAResource() throws {
        let package = try String(contentsOf: Self.sourcesURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains(#"resources: [.process("Resources/PrivacyInfo.xcprivacy")]"#))
        XCTAssertNotNil(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    }
}

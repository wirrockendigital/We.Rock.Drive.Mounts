import Foundation
import XCTest
@testable import WRDMCore

// Historical fixtures prove upgrade behavior independently from the current model encoder.
final class ConfigurationUpgradeTests: XCTestCase {
    // Migration may add schema-seven fields; subsequent reloads preserve bytes and existing values.
    func testSchemaSixLoginSurvivesUpgradeAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "schema-6", withExtension: "plist", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: fixture)
        try original.write(to: paths.configFile)
        let store = ConfigurationStore(paths: paths)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(loaded.general.openAppAtLogin)
        XCTAssertEqual(loaded.general.maximumAutomaticRecoveryAttempts, 3)
        let migratedBytes = try Data(contentsOf: paths.configFile)
        _ = try await store.load()
        XCTAssertEqual(try Data(contentsOf: paths.configFile), migratedBytes)
        _ = try await store.update { $0.general.openAppAtLogin = false }
        _ = try await store.update { $0.general.openAppAtLogin = true }
        let restarted = try await ConfigurationStore(paths: paths).load()
        XCTAssertEqual(restarted, loaded)
        let before = try XCTUnwrap(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        var after = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: paths.configFile), format: nil) as? [String: Any])
        after["schemaVersion"] = before["schemaVersion"]
        var network = try XCTUnwrap(after["network"] as? [String: Any])
        XCTAssertNotNil(network.removeValue(forKey: "discovery"))
        after["network"] = network
        XCTAssertEqual(before as NSDictionary, after as NSDictionary)
    }

    // A future version must be recognized before obsolete required fields are decoded.
    func testFutureSchemaIsNeitherOverwrittenNorBackedUpAsCorrupt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(homeDirectory: root)
        try paths.ensureDirectories()
        let future = AppSettings.currentSchemaVersion + 1
        let data = try PropertyListSerialization.data(fromPropertyList: ["schemaVersion": future, "futureSettings": "new layout"], format: .xml, options: 0)
        try data.write(to: paths.configFile)
        let store = ConfigurationStore(paths: paths)
        for _ in 0..<2 {
            do {
                _ = try await store.update { $0.general.openAppAtLogin = false }
                XCTFail("An unsupported version must block every settings mutation")
            } catch let error as ConfigurationError {
                XCTAssertEqual(error, .unsupportedSchema(future))
            }
        }
        XCTAssertEqual(try Data(contentsOf: paths.configFile), data)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: paths.applicationSupport.path).contains { $0.hasPrefix("config.corrupt-") })
    }
}

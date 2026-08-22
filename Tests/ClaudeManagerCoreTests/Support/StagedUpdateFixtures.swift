import Foundation
@testable import ClaudeManagerCore

/// Arm a staged newer Claude bundle referenced by the env's ShipItState path — the
/// precondition for every `applyStagedUpdateToAll` test.
func armStagedUpdate(_ env: StoreEnv, stagedVersion: String) throws {
    let bundle = env.root.appendingPathComponent("update.X/Claude.app")
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try PropertyListSerialization
        .data(fromPropertyList: ["CFBundleShortVersionString": stagedVersion], format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    try JSONSerialization
        .data(withJSONObject: ["updateBundleURL": bundle.absoluteString])
        .write(to: URL(fileURLWithPath: env.shipItStatePath))
}

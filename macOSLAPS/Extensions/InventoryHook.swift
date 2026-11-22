/*
===============================================================================
 macOSLAPS | Extensions | InventoryHook.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-10
 Updated:   2026-11-17

 Purpose:
     The InventoryHook: a command run after a password change so the MDM
     collects it sooner (jamf recon, or a custom command). Never runs
     inside itself.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-17   joshua    Moved from Reporting.swift, unchanged.
                        claude
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------ //
// | Inventory hook | //
// ------------------ //
// Runs jamf recon or a custom command after a change, never inside itself.  //
enum InventoryHook {
    /// Set in the hook's environment so macOSLAPS runs started by it (for example an
    /// extension attribute run by `jamf recon`) never rotate or start the hook again.
    static let environmentMarker = "MACOSLAPS_INVENTORY_HOOK"

    /// Whether a successful run of the configured hook means inventory was collected
    /// (jamf recon does; a custom command only when InventoryHookConfirms is true).
    static var confirmsExports : Bool {
        switch (GetPreference(preference_key: "InventoryHook") as? String ?? "").lowercased() {
        case "jamf": return true
        case "custom": return GetPreference(preference_key: "InventoryHookConfirms") as? Bool ?? false
        default: return false
        }
    }

    /// Runs the configured hook (if any) and waits up to `timeout` seconds. Never fatal.
    /// Returns true when a hook ran and exited 0.
    @discardableResult
    static func run(reason: String, timeout: TimeInterval = 300) -> Bool {
        // The rotation is finished; don't make other runs wait for the hook.
        RunLock.release()
        if Constants.inside_hook { return false }
        let mode = (GetPreference(preference_key: "InventoryHook") as? String ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        var command: [String]
        switch mode {
        case "", "none":
            return false
        case "jamf":
            command = ["/usr/local/bin/jamf", "recon"]
        case "custom":
            command = GetPreference(preference_key: "InventoryHookCommand") as? [String] ?? []
        default:
            laps_log.print("Unknown InventoryHook \"\(mode)\". Use jamf or custom.", .warn)
            return false
        }
        guard let executable = command.first, FileManager.default.isExecutableFile(atPath: executable) else {
            laps_log.print("InventoryHook \(mode): \(command.first ?? "no command") is not an executable file. Skipped.", .warn)
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment[environmentMarker] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            laps_log.print("InventoryHook \(mode) could not start: \(describe(error))", .warn)
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if process.isRunning {
            process.terminate()
            laps_log.print("InventoryHook \(mode) (after \(reason)) did not finish within \(Int(timeout)) seconds and was stopped.", .warn)
            return false
        } else if process.terminationStatus == 0 {
            laps_log.print("InventoryHook \(mode) ran after \(reason).", .info)
            return true
        } else {
            laps_log.print("InventoryHook \(mode) (after \(reason)) exited with status \(process.terminationStatus).", .warn)
            return false
        }
    }
}

/*
===============================================================================
 macOSLAPS | Extensions | Migration.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-11
 Updated:   2026-11-11

 Purpose:
     Moves the password stored by macOSLAPS 3.x / 4.0.0 (845) to the 4.0
     keychain items. The old items trust only code signed
     edu.psu.macOSLAPS, so macOSLAPS (now com.joshua-d-miller.macoslaps)
     asks the helper inside its bundle (Contents/Helpers/macOSLAPS-legacy,
     still signed edu.psu.macOSLAPS) to read them. The helper only works
     for root with the signed macOSLAPS as its parent, and the password
     travels over a pipe, never on a command line.

 How it fits:
     1. Candidates: the old item (through the helper), the -getPassword
     export, the 3.x plaintext file, and a staged password after an
     interrupted rotation.
     2. The first that works for the account is stored, keeping its
     creation date.
     3. A staged password moves to the new pending item.
     4. The old items are overwritten, then deleted by root's security;
     3.x plaintext files are removed.
     5. Nothing works but an old item exists: "migration required" until
     -firstPass.
     Removed in 5.0 with the helper.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file: migration through the legacy
                        claude    helper, fallbacks, "migration required",
                                  cleanup; AppBundle paths and the
                                  /usr/local/laps deprecation check.

                                  New header and section style.
===============================================================================
*/

import Foundation
import OpenDirectory

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------------------- //
// | Paths in the app bundle | //
// --------------------------- //
// Where this process was started from, and the helper and resources inside  //
// the app.                                                                  //
/// Paths inside macOSLAPS.app, found from the running executable.
enum AppBundle {
    /// The path this process was started with (not resolved: /usr/local/laps/macOSLAPS
    /// when started through the old symlink).
    static var launchPath : String? {
        var size : UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }
    static let installedExecutable = "/Applications/macOSLAPS.app/Contents/MacOS/macOSLAPS"
    static let legacyPath = "/usr/local/laps/macOSLAPS"

    /// Started through /usr/local/laps (deprecated; the symlink is removed in 5.0).
    static var startedFromLegacyPath : Bool {
        launchPath.map { $0.hasPrefix("/usr/local/laps/") } ?? false
    }

    /// `relative` under the bundle's Contents directory, if it exists and is executable.
    static func executable(_ relative: String) -> String? {
        guard let launch = launchPath else { return nil }
        let contents = URL(fileURLWithPath: launch).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = contents.appendingPathComponent(relative).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------- //
// | Migration | //
// ------------- //
// Runs once per root run before anything reads the keychain.                //
enum Migration {
    static let exportNameFile = "/var/root/.GeneratedLAPSServiceName"
    static let plaintextPassword = "/var/root/Library/Application Support/macOSLAPS-password"
    static let plaintextExpiration = "/var/root/Library/Application Support/macOSLAPS-expiration"

    // MARK: State shown by -status

    /// "none" (nothing to migrate), "migrated", or "required".
    static var status : String {
        if RunState.value("migrationRequired") != nil { return "required" }
        if RunState.value("migratedAt") != nil { return "migrated" }
        return "none"
    }

    // MARK: Helper

    /// Contents/Helpers/macOSLAPS-legacy in this app bundle.
    static func helperPath() -> String? {
        AppBundle.executable("Helpers/macOSLAPS-legacy")
    }

    struct HelperResult {
        let status: Int32
        let output: Data
        let error: String
    }

    /// Runs the helper. Its stdout (the password, for `read`) stays in memory.
    static func runHelper(_ verb: String, _ service: String) -> HelperResult? {
        guard let path = helperPath() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = [verb, service]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        var output = Data(), error = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { output = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { error = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(30)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if task.isRunning { task.terminate() }
        task.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)
        let message = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return HelperResult(status: task.terminationStatus, output: output, error: message)
    }

    /// Reads an old item through the helper: (password, comment), or nil with a reason.
    static func helperRead(_ service: String) -> (password: String, comment: String)? {
        guard let result = runHelper("read", service) else {
            laps_log.print("The migration helper (Contents/Helpers/macOSLAPS-legacy) is missing or could not start.", .warn)
            return nil
        }
        guard result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: String],
              let password = json["password"], !password.isEmpty else {
            laps_log.print("The migration helper could not read \(service) (exit \(result.status)\(result.error.isEmpty ? "" : ": \(result.error)")).", .warn)
            return nil
        }
        return (password, json["comment"] ?? "")
    }

    /// "Created: 2026-11-01 10:00:00" → "2026-11-01 10:00:00" when it parses.
    static func creationDate(fromComment comment: String?) -> String? {
        guard let text = comment, text.hasPrefix("Created: ") else { return nil }
        let date = String(text.dropFirst("Created: ".count))
        return Constants.dateFormatter.date(from: date) == nil ? nil : date
    }

    // MARK: Run

    /// Called once per root run, before anything reads the keychain. `fatal`: stop the
    /// run when migration is required (rotation, -escrow); -status, -firstPass and
    /// -initialize continue, the last two to recover.
    static func run(fatal: Bool, rotationRun: Bool) {
        guard getuid() == 0 else { return }
        if KeychainService.loadPassword(service: KeychainNames.current).0 != nil {
            retireLeftovers()
            return
        }
        guard let legacy = KeychainService.itemAttributes(service: KeychainNames.legacyCurrent) else {
            laps_log.print("Could not check the System keychain for a password stored by an earlier macOSLAPS.", .warn)
            return
        }
        guard legacy.exists else {
            // Fresh install (or already migrated and retired).
            retireLeftovers()
            return
        }
        // One migration at a time; another run may have finished it while we waited.
        RunLock.acquire()
        defer { RunLock.release() }
        if KeychainService.loadPassword(service: KeychainNames.current).0 != nil {
            retireLeftovers()
            return
        }
        migrate(legacyComment: legacy.comment, fatal: fatal, rotationRun: rotationRun)
    }

    private static func migrate(legacyComment: String?, fatal: Bool, rotationRun: Bool) {
        laps_log.print("Migrating the password stored by an earlier macOSLAPS to the new keychain item.", .info)
        guard let node = try? ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: nil) else {
            laps_log.print("Cannot migrate yet: the local admin \(Constants.local_admin) was not found. Check LocalAdminAccount.", .warn)
            return
        }
        let pendingExists = KeychainService.itemAttributes(service: KeychainNames.legacyPending)?.exists == true
        let pending = pendingExists ? helperRead(KeychainNames.legacyPending) : nil

        // Candidates in order; each is tried against the account once.
        var tried = Set<String>()
        var adopted : (password: String, source: String, created: String?)?
        func attempt(_ password: String?, _ source: String, _ created: String?) {
            guard adopted == nil, let pw = password, !pw.isEmpty, !tried.contains(pw) else { return }
            tried.insert(pw)
            if (try? record.verifyPassword(pw)) != nil {
                adopted = (pw, source, created)
            }
        }
        let fromItem = helperRead(KeychainNames.legacyCurrent)
        let created = creationDate(fromComment: fromItem?.comment) ?? creationDate(fromComment: legacyComment)
        attempt(fromItem?.password, "keychain", created)
        if adopted == nil,
           let name = (try? String(contentsOfFile: exportNameFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            attempt(KeychainService.passwordViaSecurity(service: name), "getPassword export", created)
        }
        if adopted == nil, let text = try? String(contentsOfFile: plaintextPassword, encoding: .utf8) {
            attempt(text.trimmingCharacters(in: .newlines), "3.x plaintext file", created)
        }
        // An apply interrupted after the account changed: the pending one is the password.
        // Only tried then, so a normal staged password doesn't add a failed login.
        if Staging.interruptedApply {
            attempt(pending?.password, "pending item", nil)
        }

        guard let found = adopted else {
            let message = "Migration required: a password stored by an earlier macOSLAPS exists, but it could not be read or does not match \(Constants.local_admin). Run macOSLAPS -firstPass <current password> (add -initialize to keep it without rotating)."
            RunState.set(["migrationRequired": message], remove: ["legacyRetired"])
            laps_log.print(message, fatal ? .error : .warn)
            if fatal {
                if rotationRun { RunState.record("failed", message: message) }
                exit(1)
            }
            return
        }

        let status = KeychainService.savePassword(service: KeychainNames.current, account: Constants.local_admin,
                                                  data: found.password, created: found.created)
        guard status == noErr, KeychainService.loadPassword(service: KeychainNames.current).0 == found.password else {
            laps_log.print("Unable to store the migrated password in the new keychain item (OSStatus \(status)). The earlier item was left in place.", .error)
            if fatal { exit(1) }
            return
        }
        RunState.noteVerified(true, created: found.created)

        if found.source == "pending item" {
            // The pending password became the account's password before the upgrade.
            RunState.set([:], remove: ["applying", "pendingExports", "pendingStaged", "pendingHookConfirmed"])
        } else if let staged = pending {
            let pendingStatus = KeychainService.savePassword(service: KeychainNames.pending, account: Constants.local_admin,
                                                             data: staged.password, created: creationDate(fromComment: staged.comment))
            if pendingStatus != noErr {
                laps_log.print("The staged password could not be migrated (OSStatus \(pendingStatus)); a new one will be staged.", .warn)
                RunState.set([:], remove: ["applying", "pendingExports", "pendingStaged", "pendingHookConfirmed"])
            }
        } else if pendingExists {
            laps_log.print("A staged password from the earlier macOSLAPS could not be read; a new one will be staged.", .warn)
            RunState.set([:], remove: ["applying", "pendingExports", "pendingStaged", "pendingHookConfirmed"])
        }

        RunState.set(["migratedAt": RunState.iso.string(from: Date()), "migratedFrom": found.source],
                     remove: ["migrationRequired"])
        laps_log.print("Migrated the password for \(Constants.local_admin) from the \(found.source). Rotation stays on its existing schedule.", .info)
        retireLeftovers(force: true)
    }

    /// Removes what earlier versions left behind, once a new item exists or there was
    /// nothing to migrate: the old items (overwritten first, so a failed delete leaves no
    /// usable password) and 3.x plaintext files. Runs until it has succeeded once.
    static func retireLeftovers(force: Bool = false) {
        guard getuid() == 0 else { return }
        if !force && RunState.value("legacyRetired") == "yes" && RunState.value("migrationRequired") == nil { return }
        var clean = true
        for service in [KeychainNames.legacyCurrent, KeychainNames.legacyPending] {
            guard let item = KeychainService.itemAttributes(service: service) else { clean = false; continue }
            guard item.exists else { continue }
            if let result = runHelper("tombstone", service), result.status != 0 {
                laps_log.print("Could not overwrite the old \(service) item (exit \(result.status)); deleting it.", .warn)
            }
            if KeychainService.deleteAsRoot(service: service) {
                laps_log.print("Removed the old \(service) keychain item.", .info)
            } else {
                laps_log.print("Could not remove the old \(service) keychain item. It will be retried on the next run.", .warn)
                clean = false
            }
        }
        for file in [plaintextPassword, plaintextExpiration] where FileManager.default.fileExists(atPath: file) {
            if (try? FileManager.default.removeItem(atPath: file)) != nil {
                laps_log.print("Removed the macOSLAPS 3.x plaintext file \(file).", .info)
            } else {
                clean = false
            }
        }
        RunState.set(clean ? ["legacyRetired": "yes"] : [:], remove: clean ? ["migrationRequired"] : [])
    }
}

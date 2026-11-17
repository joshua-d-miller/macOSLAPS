/*
===============================================================================
 macOSLAPS | Extensions | RunState.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-10
 Updated:   2026-11-17

 Purpose:
     Non-secret state kept between runs in /var/db/macoslaps/state.plist:
     the last run and its result, staging counters, migration, reveal and
     deadline values, and a cached result of checking the stored password.
     Never a password.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-17   joshua    Moved from Reporting.swift, unchanged,
                        claude    with isoDate.
===============================================================================
*/

import Foundation
import OpenDirectory

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------------- //
// | State between runs | //
// ---------------------- //
// /var/db/macoslaps/state.plist: last run, staging counters, migration, and //
// a cached result of checking the stored password. Never a password.        //
/// Non-secret state kept between runs in /var/db/macoslaps/state.plist (root only):
/// the last rotation run's time, result and error, and a cached result of checking the
/// stored password against the account. No password is ever written here.
enum RunState {
    static let directory = "/var/db/macoslaps"
    static let path = directory + "/state.plist"
    /// Re-check a stored password against the account at most this often.
    static let verifyInterval : TimeInterval = 24 * 60 * 60

    static let iso : ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    /// With fractional seconds, for comparing with file times (deadlineSetAt).
    static let preciseISO : ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func load() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return dict
    }
    /// Written to a 600 temporary file and renamed over the old one, so a reader never
    /// sees half a file.
    private static func save(_ dict: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        let temporary = path + ".tmp"
        guard fm.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary, path) != 0 { unlink(temporary) }
    }
    /// The check daemon, the service and commands such as -expireIn and -escrow can all
    /// change the state at once. Each load-change-save holds an exclusive lock, so one
    /// can't write back a stale copy over another's change.
    private static func update(_ change: (inout [String: Any]) -> Void) {
        guard getuid() == 0 else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory + "/.state.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        var dict = load()
        change(&dict)
        save(dict)
    }

    // MARK: Generic values (used by Staging)

    static func value(_ key: String) -> String? { load()[key] as? String }
    static func intValue(_ key: String) -> Int { (load()[key] as? NSNumber)?.intValue ?? 0 }
    static func arrayValue(_ key: String) -> [String] { load()[key] as? [String] ?? [] }
    static func set(_ values: [String: Any], remove: [String] = []) {
        update { d in
            for (k, v) in values { d[k] = v }
            for k in remove { d.removeValue(forKey: k) }
        }
        // The menu bar agent follows the deadline through a world-readable copy.
        if values["rotatesAt"] != nil || remove.contains("rotatesAt") { Reveal.publishDeadline() }
    }

    // MARK: Last run

    /// Set once a rotation run starts; errors logged after that are remembered.
    static var tracking = false
    static var lastError : String?
    private static var recorded = false

    static func begin() {
        tracking = true
        atexit {
            // Exits without an explicit result (error paths call exit(1)) are failures.
            if RunState.tracking && !RunState.recordedResult {
                RunState.record("failed", message: RunState.lastError ?? "exited without completing")
            }
        }
    }
    static var recordedResult : Bool { recorded }

    /// result: rotated, not-due, initialized, failed.
    static func record(_ result: String, message: String? = nil) {
        recorded = true
        if result == "rotated" { Reveal.afterRotation() }
        if result == "rotated" || result == "initialized" {
            update { d in Ownership.stateKeys.forEach { d.removeValue(forKey: $0) } }
        }
        update { d in
            d["lastRun"] = iso.string(from: Date())
            d["lastResult"] = result
            if let message = message { d["lastMessage"] = message } else { d.removeValue(forKey: "lastMessage") }
            if result != "failed" { d["lastSuccess"] = iso.string(from: Date()) }
        }
    }

    static func lastRun() -> (run: String?, result: String?, message: String?, success: String?) {
        let d = load()
        return (d["lastRun"] as? String, d["lastResult"] as? String, d["lastMessage"] as? String, d["lastSuccess"] as? String)
    }

    // MARK: Cached password check

    /// Whether `password` (the stored one, created at `created`) works for the account.
    /// A failed check is remembered for verifyInterval per stored password, so inventory
    /// scripts running -status/-escrow/-getPassword don't add a failed login every time
    /// when the keychain and the account disagree.
    static func storedPasswordWorks(_ password: String, created: String?, record: ODRecord, force: Bool = false) -> Bool {
        let key = created ?? "unknown"
        let d = load()
        // Only a failure is reused: checking a password that works never counts toward a
        // lockout, so a success is re-checked every time (and catches manual changes).
        if !force, d["verifiedItem"] as? String == key,
           let at = (d["verifiedAt"] as? String).flatMap(iso.date(from:)),
           Date().timeIntervalSince(at) < verifyInterval,
           d["verifiedResult"] as? Bool == false {
            return false
        }
        let works = (try? record.verifyPassword(password)) != nil
        noteVerified(works, created: created)
        return works
    }

    /// Records a password check done elsewhere (e.g. right after a rotation).
    static func noteVerified(_ works: Bool, created: String?) {
        update { d in
            d["verifiedItem"] = created ?? "unknown"
            d["verifiedAt"] = iso.string(from: Date())
            d["verifiedResult"] = works
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------- //
// | Date for JSON | //
// ---------------- //
// Keychain dates as ISO 8601 with the time zone offset.                     //
/// Converts a macOSLAPS date ("yyyy-MM-dd HH:mm:ss", local time, as stored in the keychain
/// comment) to ISO 8601 with the time zone offset for JSON output. Unparseable → as is.
func isoDate(_ legacy: String?) -> String? {
    guard let text = legacy else { return nil }
    guard let date = Constants.dateFormatter.date(from: text) else { return text }
    return RunState.iso.string(from: date)
}

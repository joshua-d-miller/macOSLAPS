///
///  Reporting.swift
///  macOSLAPS
///
///  Created November 10, 2026
///
///  `-status`     one line of JSON for an MDM inventory attribute / smart group
///  `-status -v`  the same checks as a readable checklist for a technician
///  InventoryHook optional command run after a password change so the MDM
///                picks up the new escrow value sooner (e.g. `jamf recon`)

import Foundation
import OpenDirectory
import Security

struct StatusReport: Codable {
    var v = 1
    var version: String
    var method: String
    var adSchema: String?
    var account: String
    var accountExists: Bool
    var accountIsAdmin: Bool?
    var accountHidden: Bool?
    var secureToken: Bool?
    var fileVault: Bool?
    var recoveryKeyEscrowProfile: Bool?
    var bootstrapTokenEscrowed: Bool?
    var passwordStored: Bool
    var passwordVerifies: Bool?
    /// True when the account's password is still the FirstPass from the configuration,
    /// i.e. a known, shared password that local users can read from the profile.
    var passwordIsFirstPass: Bool?
    var lastRotation: String?
    var expires: String?
    var escrow: String
    var escrowCertificates: [String]
    var escrowCertificatesExpire: String?
    var inventoryHook: String
    var stagedRotation: String
    var pending: Bool
    var pendingSince: String?
    var pendingExports: Int?
    var pendingExportsNeeded: Int?
    var lastRun: String?
    var lastResult: String?
    var lastMessage: String?
    var lastSuccess: String?
    var settingsDomain: String
    var settingsSource: String
    var osVersion: String
}

enum Status {
    private static func shell(_ path: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        return Shell.run(launchPath: path, arguments: args)
    }

    static func collect() -> StatusReport {
        let prefs = PreferenceStore.shared
        let account = Constants.local_admin
        var record : ODRecord? = nil
        if let node = try? ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)) {
            record = try? node.record(withRecordType: kODRecordTypeUsers, name: account, attributes: nil)
        }
        let exists = record != nil

        var isAdmin: Bool? = nil, hidden: Bool? = nil, token: Bool? = nil
        if exists {
            if let node = try? ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)),
               let admins = try? node.record(withRecordType: kODRecordTypeGroups, name: "admin", attributes: nil),
               let user = record {
                isAdmin = (try? admins.isMemberRecord(user)) != nil
            }
            hidden = ((try? record?.values(forAttribute: "dsAttrTypeNative:IsHidden"))?.first as? String).map { $0 == "1" || $0.uppercased() == "YES" } ?? false
            switch secureTokenStatus(for: account) {
            case .enabled: token = true
            case .disabled: token = false
            case .unknown: token = nil
            }
        }
        let fv = shell("/usr/bin/fdesetup", ["status"]).contains("FileVault is On")
        let prk = shell("/usr/bin/profiles", ["show", "-type", "configuration"]).contains("com.apple.security.FDERecoveryKeyEscrow")
        let bootstrapOutput = shell("/usr/bin/profiles", ["status", "-type", "bootstraptoken"])
        let bootstrap: Bool? = bootstrapOutput.contains("escrowed to server: YES") ? true
            : (bootstrapOutput.contains("escrowed to server: NO") ? false : nil)

        let (password, created) = KeychainService.loadPassword(service: "macOSLAPS")
        var verifies: Bool? = nil
        if let pw = password, let rec = record {
            verifies = RunState.storedPasswordWorks(pw, created: created, record: rec)
        }
        let configuredFirstPass = GetPreference(preference_key: "FirstPass") as? String ?? ""
        var isFirstPass: Bool? = nil
        if !configuredFirstPass.isEmpty {
            if verifies == true {
                // The stored password is the live one, so a comparison answers it without
                // another (possibly failing) authentication against the account.
                isFirstPass = (password == configuredFirstPass)
            }
            // Otherwise unknown: checking FirstPass against the account on every inventory
            // could add failed logins toward a lockout policy.
        }
        let createdDate = (created == nil || created == "Not Found") ? nil : created
        let expires = password == nil ? nil : LocalTools.get_expiration_date().map { Constants.dateFormatter.string(from: $0) }
        let staged = Staging.pending()
        let certConfig = Escrow.certificateConfig()
        let certs = certConfig.certificates
        let hook = (GetPreference(preference_key: "InventoryHook") as? String ?? "").lowercased()
        let osv = ProcessInfo.processInfo.operatingSystemVersion

        return StatusReport(
            version: fullVersion(),
            method: Constants.method,
            adSchema: Constants.method == "AD" ? ADTools.schema : nil,
            account: account,
            accountExists: exists,
            accountIsAdmin: isAdmin,
            accountHidden: hidden,
            secureToken: token,
            fileVault: fv,
            recoveryKeyEscrowProfile: prk,
            bootstrapTokenEscrowed: bootstrap,
            passwordStored: password != nil,
            passwordVerifies: verifies,
            passwordIsFirstPass: isFirstPass,
            lastRotation: isoDate(createdDate),
            expires: isoDate(expires),
            escrow: certConfig.unusable ? "error" : (certConfig.configured ? "cms" : "plaintext"),
            escrowCertificates: certs.map { String(Escrow.fingerprint($0).prefix(16)) },
            escrowCertificatesExpire: earliestExpiry(certs).map { RunState.iso.string(from: $0) },
            inventoryHook: hook.isEmpty ? "none" : hook,
            stagedRotation: Staging.mode + (Staging.active ? " (active)" : " (inactive)"),
            pending: staged != nil,
            pendingSince: isoDate(staged?.created),
            pendingExports: staged == nil ? nil : Staging.exports,
            pendingExportsNeeded: staged == nil ? nil : Staging.confirmationsNeeded,
            lastRun: RunState.lastRun().run,
            lastResult: RunState.lastRun().result,
            lastMessage: RunState.lastRun().message,
            lastSuccess: RunState.lastRun().success,
            settingsDomain: prefs.domain,
            settingsSource: prefs.source.rawValue,
            osVersion: "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)")
    }

    static func run(verbose: Bool) -> Never {
        let report = collect()
        if !verbose {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(data: try! encoder.encode(report), encoding: .utf8)!)
            exit(0)
        }
        func line(_ ok: Bool?, _ text: String, _ fix: String? = nil) {
            let mark = ok == nil ? "⚪️" : (ok! ? "✅" : "❌")
            print("\(mark) \(text)" + ((ok == false && fix != nil) ? "\n     → \(fix!)" : ""))
        }
        func warnLine(_ text: String) { print("⚠️  \(text)") }
        PreferenceStore.shared.emitNotices()
        print("macOSLAPS \(report.version) status on macOS \(report.osVersion)\n")
        print("Settings: \(report.settingsDomain) (\(report.settingsSource))")
        print("Method: \(report.method)\(report.adSchema.map { " (ADSchema \($0))" } ?? "")\n")
        if let schema = report.adSchema, schema != "legacy" {
            warnLine("ADSchema \(schema) is experimental in 4.0: not yet tested from a Mac against a production domain. Please report results.")
        }
        line(report.accountExists, "Local admin account \(report.account) exists",
             "Create the account, or set LocalAdminAccount to the right name.")
        if report.accountExists {
            line(report.accountIsAdmin, "\(report.account) is an administrator", "Add it to the admin group.")
            print("ℹ️  Hidden from the login window: \(report.accountHidden == true ? "yes" : "no")")
            if report.secureToken == nil {
                warnLine("Could not determine whether \(report.account) has a secureToken; rotation will require the current password.")
            } else if report.secureToken == true {
                line(true, "\(report.account) has a secureToken (rotation needs the current password)")
            } else {
                warnLine("\(report.account) has no secureToken: it can't unlock FileVault, but rotation is a simple reset.")
            }
        }
        print("ℹ️  FileVault: \(report.fileVault == true ? "on" : "off")")
        print("ℹ️  FileVault recovery key escrow profile installed: \(report.recoveryKeyEscrowProfile == true ? "yes" : "no")")
        if let bt = report.bootstrapTokenEscrowed { print("ℹ️  Bootstrap Token escrowed to MDM: \(bt ? "yes" : "no")") }
        line(report.passwordStored, "A macOSLAPS password is stored",
             "Run macOSLAPS -firstPass <current password> (secureToken) or macOSLAPS -resetPassword.")
        if report.passwordStored {
            line(report.passwordVerifies, "The stored password works for \(report.account)",
                 "The account and keychain disagree. Reset the account and run macOSLAPS -firstPass <password>.")
            print("ℹ️  Last rotation: \(report.lastRotation ?? "unknown")   Expires: \(report.expires ?? "unknown")")
        }
        if report.passwordIsFirstPass == true {
            line(false, "\(report.account)'s password has been rotated away from FirstPass",
                 "The account still uses the FirstPass from the configuration, which local users can read. Run macOSLAPS -resetPassword and remove FirstPass from the profile.")
        }
        if report.escrow == "error" {
            line(false, "Escrow encryption is configured but unusable",
                 "Fix EscrowCertificates (RSA certificates, PEM or base64 DER). -escrow will not print the password until it is fixed.")
        }
        print("ℹ️  Escrow: \(report.escrow)" + (report.escrowCertificates.isEmpty ? "" : " to \(report.escrowCertificates.count) certificate(s): \(report.escrowCertificates.joined(separator: ", "))"))
        print("ℹ️  Inventory hook: \(report.inventoryHook)")
        print("ℹ️  Staged rotation: \(report.stagedRotation)")
        if report.pending {
            print("ℹ️  A new password is staged since \(report.pendingSince ?? "?"): collected by the MDM \(report.pendingExports ?? 0) of \(report.pendingExportsNeeded ?? 0) time(s). It becomes the account's password after that.")
        }
        if let expires = report.escrowCertificatesExpire.flatMap(RunState.iso.date(from:)) {
            let days = Int(expires.timeIntervalSinceNow / 86400)
            if days < 0 { line(false, "An escrow certificate has expired", "Replace it in EscrowCertificates.") }
            else if days < 30 { warnLine("An escrow certificate expires in \(days) day(s) (\(report.escrowCertificatesExpire!)).") }
        }
        if let result = report.lastResult {
            line(result != "failed", "Last run \(report.lastRun ?? "?"): \(result)" + (report.lastMessage.map { " — \($0)" } ?? ""),
                 "Check /Library/Logs/macOSLAPS.log. Last successful run: \(report.lastSuccess ?? "never").")
        } else {
            print("ℹ️  No rotation run recorded yet on this build.")
        }
        exit(0)
    }
}

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

    private static func load() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return dict
    }
    private static func save(_ dict: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
    private static func update(_ change: (inout [String: Any]) -> Void) {
        guard getuid() == 0 else { return }
        var dict = load()
        change(&dict)
        save(dict)
    }

    // MARK: Generic values (used by Staging)

    static func value(_ key: String) -> String? { load()[key] as? String }
    static func intValue(_ key: String) -> Int { (load()[key] as? NSNumber)?.intValue ?? 0 }
    static func set(_ values: [String: Any], remove: [String] = []) {
        update { d in
            for (k, v) in values { d[k] = v }
            for k in remove { d.removeValue(forKey: k) }
        }
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

/// Earliest expiry among certificates (nil if none or unreadable).
func earliestExpiry(_ certs: [SecCertificate]) -> Date? {
    certs.compactMap { cert -> Date? in
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let number = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }.min()
}

/// Converts a macOSLAPS date ("yyyy-MM-dd HH:mm:ss", local time, as stored in the keychain
/// comment) to ISO 8601 with the time zone offset for JSON output. Unparseable → as is.
func isoDate(_ legacy: String?) -> String? {
    guard let text = legacy else { return nil }
    guard let date = Constants.dateFormatter.date(from: text) else { return text }
    return RunState.iso.string(from: date)
}

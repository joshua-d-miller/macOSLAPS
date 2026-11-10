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
    var inventoryHook: String
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
            verifies = (try? rec.verifyPassword(pw)) != nil
        }
        let configuredFirstPass = GetPreference(preference_key: "FirstPass") as? String ?? ""
        var isFirstPass: Bool? = nil
        if !configuredFirstPass.isEmpty {
            if verifies == true {
                // The stored password is the live one, so a comparison answers it without
                // another (possibly failing) authentication against the account.
                isFirstPass = (password == configuredFirstPass)
            } else if let rec = record {
                isFirstPass = (try? rec.verifyPassword(configuredFirstPass)) != nil
            }
        }
        let createdDate = (created == nil || created == "Not Found") ? nil : created
        let expires = password == nil ? nil : LocalTools.get_expiration_date().map { Constants.dateFormatter.string(from: $0) }
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
            lastRotation: createdDate,
            expires: expires,
            escrow: certConfig.unusable ? "error" : (certConfig.configured ? "cms" : "plaintext"),
            escrowCertificates: certs.map { String(Escrow.fingerprint($0).prefix(16)) },
            inventoryHook: hook.isEmpty ? "none" : hook,
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
        exit(0)
    }
}

enum InventoryHook {
    /// Set in the hook's environment so macOSLAPS runs started by it (for example an
    /// extension attribute run by `jamf recon`) never rotate or start the hook again.
    static let environmentMarker = "MACOSLAPS_INVENTORY_HOOK"

    /// Runs the configured hook (if any) and waits up to `timeout` seconds. Never fatal.
    static func run(reason: String, timeout: TimeInterval = 300) {
        // The rotation is finished; don't make other runs wait for the hook.
        RunLock.release()
        if Constants.inside_hook { return }
        let mode = (GetPreference(preference_key: "InventoryHook") as? String ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        var command: [String]
        switch mode {
        case "", "none":
            return
        case "jamf":
            command = ["/usr/local/bin/jamf", "recon"]
        case "custom":
            command = GetPreference(preference_key: "InventoryHookCommand") as? [String] ?? []
        default:
            laps_log.print("Unknown InventoryHook \"\(mode)\". Use jamf or custom.", .warn)
            return
        }
        guard let executable = command.first, FileManager.default.isExecutableFile(atPath: executable) else {
            laps_log.print("InventoryHook \(mode): \(command.first ?? "no command") is not an executable file. Skipped.", .warn)
            return
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
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if process.isRunning {
            process.terminate()
            laps_log.print("InventoryHook \(mode) (after \(reason)) did not finish within \(Int(timeout)) seconds and was stopped.", .warn)
        } else if process.terminationStatus == 0 {
            laps_log.print("InventoryHook \(mode) ran after \(reason).", .info)
        } else {
            laps_log.print("InventoryHook \(mode) (after \(reason)) exited with status \(process.terminationStatus).", .warn)
        }
    }
}

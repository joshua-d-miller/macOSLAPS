/*
===============================================================================
 macOSLAPS | Extensions | Status.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-10
 Updated:   2026-11-17

 Purpose:
     -status prints one line of JSON for an MDM inventory attribute or
     smart group; -status -v prints the same checks as a readable
     checklist for a technician.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-17   joshua    Split from Reporting.swift (the inventory
                        claude    hook and RunState have their own files);
                                  revealRetryAt for the reveal wait.
 4.0.0     2026-11-12   joshua    New file: -status (account, secureToken,
                        claude    FileVault, stored password, escrow, staging,
                                  migration, admin group, reveal); device mode
                                  warns without a FileVault recovery key
                                  escrow profile; externalChange; MDM-created
                                  admins.

                                  New header and section style.
===============================================================================
*/

import Foundation
import OpenDirectory
import Security

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------ //
// | -status report | //
// ------------------ //
// Every field -status prints.                                               //
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
    /// Migration from the 3.x / 845 keychain item: none, migrated, required.
    var migration: String
    var migratedAt: String?
    var migratedFrom: String?
    /// Admin group protection: policy, admins not in ApprovedAdmins, an elevation tool
    /// that makes auto report only, and the last admins macOSLAPS removed ("user time").
    var adminGroupPolicy: String
    var unapprovedAdmins: [String]
    var elevationTool: String?
    var demotedAdmins: [String]?
    /// Set when the stored password stopped working because something else changed it;
    /// macOSLAPS stops rotating until -firstPass / -initialize.
    var externalChange: String?
    var externalChangeReason: String?
    /// Admin accounts the MDM created during Automated Device Enrollment (never removed),
    /// whether that list could be read, and whether the managed admin is one of them.
    var mdmAdmins: [String]
    var mdmAdminList: String
    var localAdminIsMDMAccount: Bool
    /// Reveal / deadline: mode, when the current code was made, wrong tries, the wait
    /// after too many, whether an MDM (or AD) holds the code, the last reveal, and when
    /// the password changes.
    var retrievalMode: String
    var revealCodeSet: String?
    var revealFailures: Int?
    /// True while reveals wait after too many wrong codes, until revealRetryAt.
    var revealLocked: Bool?
    var revealRetryAt: String?
    var revealCodeCollected: Bool?
    var revealedAt: String?
    var rotatesAt: String?
    var rotateReason: String?
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------------------- //
// | -status and -status -v | //
// -------------------------- //
// Collects the checks and prints them as JSON or as a checklist.            //
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

        let stored = KeychainService.current
        let password = stored?.password, created = stored?.created
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
        let expires = password == nil ? nil : Constants.dateFormatter.string(from: LocalTools.get_expiration_date())
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
            lastRotation: isoDate(created),
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
            osVersion: "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)",
            migration: Migration.status,
            migratedAt: RunState.value("migratedAt"),
            migratedFrom: RunState.value("migratedFrom"),
            adminGroupPolicy: AdminGroup.policy,
            unapprovedAdmins: AdminGroup.unapproved(),
            elevationTool: AdminGroup.elevationTool(),
            demotedAdmins: { let d = RunState.arrayValue("demotedAdmins"); return d.isEmpty ? nil : d }(),
            externalChange: RunState.value("externalChange"),
            externalChangeReason: RunState.value("externalChangeReason"),
            mdmAdmins: MDMAccounts.createdByMDM(),
            mdmAdminList: MDMAccounts.listState,
            localAdminIsMDMAccount: MDMAccounts.isCreatedByMDM(Constants.local_admin),
            retrievalMode: Reveal.deviceMode ? "device" : "escrow",
            revealCodeSet: Reveal.deviceMode ? RunState.value("revealCodeSet") : nil,
            revealFailures: Reveal.deviceMode ? Reveal.failures : nil,
            revealLocked: Reveal.deviceMode ? Reveal.locked : nil,
            revealRetryAt: Reveal.deviceMode ? Reveal.retryAt.map { RunState.iso.string(from: $0) } : nil,
            revealCodeCollected: Reveal.deviceMode ? Reveal.codeCollected : nil,
            revealedAt: RunState.value("revealedAt"),
            rotatesAt: RunState.value("rotatesAt"),
            rotateReason: RunState.value("rotateReason"))
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
        if report.migration == "required" {
            line(false, "The password stored by an earlier macOSLAPS has been migrated",
                 RunState.value("migrationRequired") ?? "Run macOSLAPS -firstPass <current password>.")
        } else if report.migration == "migrated" {
            print("ℹ️  Migrated from an earlier macOSLAPS (\(report.migratedFrom ?? "?")) on \(report.migratedAt ?? "?")")
        }
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
        if !report.mdmAdmins.isEmpty {
            print("ℹ️  Admin accounts your MDM created (never removed): \(report.mdmAdmins.joined(separator: ", "))")
        }
        if report.mdmAdminList.hasPrefix("unreadable") {
            line(false, "The list of admin accounts your MDM created can be read (\(report.mdmAdminList))",
                 "Until it can, admin group protection removes nobody.")
        }
        if report.localAdminIsMDMAccount {
            line(false, "\(report.account) was created by your MDM, which can change its password too",
                 "If your MDM's LAPS is on for this account, let one of them own it (AllowMDMManagedAccount false makes macOSLAPS refuse).")
        }
        if let since = report.externalChange {
            line(false, "The password was changed outside macOSLAPS (noticed \(since)); rotation is stopped",
                 "Find out what changed it (another LAPS tool or the MDM?). To manage the account again: macOSLAPS -firstPass <current password> -resetPassword.")
        }
        if report.retrievalMode == "device" {
            print("ℹ️  Retrieval: device mode (reveal codes); code made \(report.revealCodeSet ?? "not yet")")
            if report.fileVault == true {
                line(report.recoveryKeyEscrowProfile, "Device mode: a FileVault recovery key escrow profile is installed",
                     "A reveal code can't unlock FileVault or the login window, and the MDM doesn't hold the password. Escrow the personal recovery key, or use RetrievalMode escrow.")
            }
            line(report.revealCodeCollected, "An MDM (or AD) holds the current reveal code",
                 "Run macOSLAPS -escrow from your MDM's inventory (or set ADRevealCode), or nobody can reveal the password.")
            if report.revealLocked == true {
                line(false, "Reveals wait until \(report.revealRetryAt ?? "?") after \(report.revealFailures ?? 0) wrong codes in a row",
                     "Wait, or run macOSLAPS -resetPassword: the rotation issues a new code and starts over.")
            }
        }
        if let at = report.rotatesAt {
            print("ℹ️  The password changes at \(at) (\(report.rotateReason ?? "scheduled"))\(report.revealedAt.map { "; revealed \($0)" } ?? "")")
        }
        if report.unapprovedAdmins.isEmpty {
            line(true, "Only approved accounts are admins (AdminGroupPolicy \(report.adminGroupPolicy))")
        } else {
            let enforced = report.adminGroupPolicy == "enforce" || (report.adminGroupPolicy == "auto" && report.elevationTool == nil)
            line(false, "Admins not in ApprovedAdmins: \(report.unapprovedAdmins.joined(separator: ", "))",
                 enforced ? "They are removed on the next run. Add them to ApprovedAdmins to keep them."
                          : "Not removed (\(report.elevationTool.map { "\($0) is installed" } ?? "AdminGroupPolicy report")). Add them to ApprovedAdmins, or remove them.")
        }
        if let demoted = report.demotedAdmins?.suffix(3), !demoted.isEmpty {
            print("ℹ️  Recently removed from the admin group: \(demoted.joined(separator: "; "))")
        }
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
                 "Check /Library/Logs/macOSLAPS.log (or log show --predicate 'subsystem == \"com.joshua-d-miller.macoslaps\"'). Last successful run: \(report.lastSuccess ?? "never").")
        } else {
            print("ℹ️  No rotation run recorded yet on this build.")
        }
        exit(0)
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------- //
// | Helpers | //
// ----------- //
// Certificate expiry for -status.                                           //
/// Earliest expiry among certificates (nil if none or unreadable).
func earliestExpiry(_ certs: [SecCertificate]) -> Date? {
    certs.compactMap { cert -> Date? in
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let number = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }.min()
}

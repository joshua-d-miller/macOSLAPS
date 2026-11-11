///
///  ADPasswordTools.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///  
///  Last Update on November 10, 2026

import Foundation
import OpenDirectory
import SystemConfiguration

// Tools that will allow for passwords to be read
// and written to Active Directory (Usually the default

public class ADTools: NSObject {

    // ADSchema: which LAPS attributes to write.
    //   legacy      ms-Mcs-AdmPwd + ms-Mcs-AdmPwdExpirationTime (default, same as 3.x)
    //   windowsLAPS msLAPS-Password (JSON {"n","t","p"}) + msLAPS-PasswordExpirationTime
    //   both        all four, for domains moving from legacy to Windows LAPS
    // Windows LAPS *encrypted* passwords (msLAPS-EncryptedPassword) are not supported:
    // they require the MS-GKDI group key protocol, which has no macOS implementation.
    static let legacyPassword = "dsAttrTypeNative:ms-Mcs-AdmPwd"
    static let legacyExpiration = "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime"
    static let windowsPassword = "dsAttrTypeNative:msLAPS-Password"
    static let windowsExpiration = "dsAttrTypeNative:msLAPS-PasswordExpirationTime"

    static var schema: String {
        let raw = (GetPreference(preference_key: "ADSchema") as? String ?? "legacy")
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch raw {
        case "windowslaps", "windows", "mslaps": return "windowsLAPS"
        case "both": return "both"
        case "legacy", "": return "legacy"
        default:
            laps_log.print("Unknown ADSchema \"\(raw)\". Using legacy. Valid values: legacy, windowsLAPS, both.", .warn)
            return "legacy"
        }
    }
    static var writesLegacy: Bool { schema != "windowsLAPS" }
    static var writesWindowsLAPS: Bool { schema != "legacy" }
    /// The expiration attribute used to decide when to rotate.
    static var expirationAttribute: String { writesLegacy ? legacyExpiration : windowsExpiration }

    /// The Windows LAPS JSON value: {"n": account, "t": update time as hex FILETIME, "p": password}.
    static func windowsLAPSValue(account: String, password: String, updated: Date = Date()) -> String {
        let filetime = UInt64((updated.timeIntervalSince1970 + 11644473600) * 10_000_000)
        let object : [String: String] = ["n": account, "t": String(filetime, radix: 16), "p": password]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)!
    }

    // Connect
    class func connect() -> Array<ODRecord> {
        // Use Open Directory to Connect to Active Directory
        // Create Net Config
        let net_config = SCDynamicStoreCreate(nil, "net" as CFString, nil, nil)
        // Get Active Directory Info
        let ad_info = [ SCDynamicStoreCopyValue(net_config, "com.apple.opendirectoryd.ActiveDirectory" as CFString)]
        // Convert ad_info variable to dictionary as it seems there is support for multiple directories
        let adDict = ad_info[0] as? NSDictionary ?? nil
        if adDict == nil {
            laps_log.print("This machine does not appear to be bound to Active Directory", .error)
            exit(1)
        }
        // Create the Active Directory Path in case Search Paths are disabled
        let ad_path = "\(adDict?["NodeName"] as! String)/\(adDict?["DomainNameDns"] as! String)"
        
        let session = ODSession.default()
        var computer_record = [ODRecord]()
        do {
            if Constants.preferred_domain_controller.isEmpty {
                laps_log.print("No Preferred Domain Controller Specified. Continuing...", .info)
            }
            else {
                laps_log.print("Using Preferred Domain Controller " + Constants.preferred_domain_controller + "...", .info)
                let od_config = ODConfiguration.init()
                od_config.preferredDestinationHostName = Constants.preferred_domain_controller
            }
            let node = try ODNode.init(session: session, name: ad_path)
            let query = try ODQuery.init(node: node, forRecordTypes: [kODRecordTypeServer, kODRecordTypeComputers], attribute: kODAttributeTypeRecordName, matchType: UInt32(kODMatchEqualTo), queryValues: adDict!["TrustAccount"], returnAttributes: kODAttributeTypeNativeOnly, maximumResults: 0)
            computer_record = (try query.resultsAllowingPartial(false) as? [ODRecord]) ?? []
        }
        catch {
            laps_log.print("Active Directory Node not available (\(describe(error))). Make sure your Active Directory is reachable via direct network connection or VPN.", .error)
            exit(1)
        }
        guard !computer_record.isEmpty else {
            laps_log.print("This Mac's computer record (\(adDict?["TrustAccount"] ?? "unknown")) was not found in Active Directory.", .error)
            exit(1)
        }
        return(computer_record)
    }
    class func check_pw_expiration(computer_record: Array<ODRecord>) -> String? {
        var expirationtime: Any = "126227988000000000" // Default of 01/01/2001 forces a change
        do {
            expirationtime = try computer_record[0].values(forAttribute: expirationAttribute)[0]
        } catch {
            laps_log.print("There has never been a random password generated for this device (no \(expirationAttribute)). Forcing a password change...", .warn)
        }
        return(expirationtime) as? String
    }
    class func verify_dc_writability(computer_record: Array<ODRecord>) {
        // Test that we can write to the domain controller we are connected to before
        // changing the local password, by rewriting the current expiration time.
        do {
            for attribute in (writesLegacy ? [legacyExpiration] : []) + (writesWindowsLAPS ? [windowsExpiration] : []) {
                if let current = try? computer_record[0].values(forAttribute: attribute), !current.isEmpty {
                    try computer_record[0].setValue(current, forAttribute: attribute)
                } else {
                    try computer_record[0].setValue("126227988000000000", forAttribute: attribute)
                }
            }
        } catch {
            laps_log.print("Unable to write the LAPS expiration attribute(s) for ADSchema \(schema) (\(describe(error))). Either the schema is missing, the computer lacks permission to write its own LAPS attributes, or the domain controller is read-only.", .error)
            exit(1)
        }
    }
    /// Rotates the account and writes AD. `staged` is the pending password when applying a
    /// staged rotation; otherwise a new password is generated.
    class func password_change(computer_record: Array<ODRecord>, staged: String? = nil) {
        let password = staged ?? PasswordGen(length: Constants.password_length)
        // Set out next expiration date in a variable x days from what we specified
        let new_ad_exp_date = TimeConversion.windows()
        // Format Expiration Date
        let print_exp_date = TimeConversion.epoch(exp_time: new_ad_exp_date!)
        let formatted_new_exp_date = Constants.dateFormatter.string(from: print_exp_date!)
        // Change and verify the local password (shared with the Local method)
        let local_admin_record = LocalTools.connect()
        CriticalSection.begin()
        if staged != nil { Staging.beginApply() }
        let previous_password = LocalTools.changeAndVerify(record: local_admin_record, to: password)

        // Write our new password to the System Keychain
        let save_status = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: password)
        guard save_status == noErr else {
            laps_log.print("New password could not be saved to the keychain (OSStatus \(save_status)). Reverting changes and exiting...", .error)
            _ = LocalTools.revert(record: local_admin_record, from: password, to: previous_password)
            exit(1)
        }
        laps_log.print("Password change has been completed locally. Performing changes to Active Directory", .info)

        // Write to Active Directory. On failure, put the account, keychain and every LAPS
        // attribute this ADSchema writes back, so AD never holds a password the Mac doesn't.
        if ADTools.set_password(computer_record: computer_record, password: password, new_ad_exp_date: new_ad_exp_date!) != 0 {
            if LocalTools.revert(record: local_admin_record, from: password, to: previous_password), let previous = previous_password {
                _ = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: previous)
                ADTools.restore(computer_record: computer_record, previousPassword: previous)
                laps_log.print("Since the Password or Expiration Time was unable to be written back to Active Directory, changes have been reverted and the application will now exit", .error)
            } else {
                ADTools.restore(computer_record: computer_record, previousPassword: nil)
                laps_log.print("Active Directory could not be updated and the local change could not be reverted. The keychain holds the current password; run macOSLAPS -resetPassword once Active Directory is reachable.", .error)
            }
            exit(1)
        }

        laps_log.print("Password change has been written to Active Directory for the local administrator \(Constants.local_admin). The new expiration date is \(formatted_new_exp_date)", .info)
        Staging.finishApply()
        CriticalSection.end()
        RunState.record("rotated")
        RunState.noteVerified(true, created: KeychainService.loadPassword(service: "macOSLAPS").1)
        LocalTools.removeAdminKeychainIfEnabled(record: local_admin_record)
        InventoryHook.run(reason: "password change")
    }
    /// Writes the new password and expiration to every attribute the ADSchema uses.
    /// Returns 0 on success, 1 if a legacy attribute failed, 2 if a Windows LAPS one failed.
    /// A failure can leave some attributes written; callers then use restore(...).
    class func set_password(computer_record: Array<ODRecord>, password: String, new_ad_exp_date: String) -> OSStatus {
        let record = computer_record[0]
        if writesWindowsLAPS && schema != "legacy" {
            ADTools.noteExperimentalSchemaOnce()
        }
        if writesLegacy {
            do {
                try record.setValue(password, forAttribute: legacyPassword)
                try record.setValue(new_ad_exp_date, forAttribute: legacyExpiration)
            } catch {
                laps_log.print("There was an error writing the legacy LAPS attributes (\(describe(error)))", .error)
                return(1)
            }
        }
        if writesWindowsLAPS {
            do {
                try record.setValue(windowsLAPSValue(account: Constants.local_admin, password: password), forAttribute: windowsPassword)
                try record.setValue(new_ad_exp_date, forAttribute: windowsExpiration)
            } catch {
                laps_log.print("There was an error writing the Windows LAPS attributes (\(describe(error)))", .error)
                return(2)
            }
        }
        return(0)
    }

    /// Best effort after a failed write: put every attribute this ADSchema uses back on
    /// the previous password, already expired so the next run rotates again. When the
    /// previous password is unknown, only the expiration is reset (to "expired").
    class func restore(computer_record: Array<ODRecord>, previousPassword: String?) {
        let record = computer_record[0]
        let expired = "126227988000000000"   // 2001-01-01
        var problems : [String] = []
        func attempt(_ value: String, _ attribute: String) {
            do { try record.setValue(value, forAttribute: attribute) }
            catch { problems.append("\(attribute.replacingOccurrences(of: "dsAttrTypeNative:", with: "")): \(describe(error))") }
        }
        if writesLegacy {
            if let previous = previousPassword { attempt(previous, legacyPassword) }
            attempt(expired, legacyExpiration)
        }
        if writesWindowsLAPS {
            if let previous = previousPassword { attempt(windowsLAPSValue(account: Constants.local_admin, password: previous), windowsPassword) }
            attempt(expired, windowsExpiration)
        }
        if problems.isEmpty {
            laps_log.print("Active Directory LAPS attributes restored\(previousPassword == nil ? " (marked expired; the previous password is unknown)" : " to the previous password, marked expired") so the next run retries.", .warn)
        } else {
            laps_log.print("Could not restore some Active Directory LAPS attributes (\(problems.joined(separator: "; "))). The directory may not match this Mac until the next successful rotation.", .error)
        }
    }

    /// Interrupted staged apply: the account already uses `password`; bring AD in line.
    class func restoreAfterInterruptedApply(computer_record: Array<ODRecord>, password: String) {
        if set_password(computer_record: computer_record, password: password, new_ad_exp_date: TimeConversion.windows()!) != 0 {
            laps_log.print("The interrupted rotation was finished locally, but Active Directory could not be updated. The next run will try again.", .error)
            restore(computer_record: computer_record, previousPassword: password)
        }
    }

    private static var experimentalNoted = false
    static func noteExperimentalSchemaOnce() {
        guard !experimentalNoted else { return }
        experimentalNoted = true
        laps_log.print("ADSchema \(schema) is new in 4.0 and experimental: it has not yet been tested from a Mac against a production domain. Please report how it works for you.", .warn)
    }
}

///
///  LocalPasswordTools.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///
///  Last Update on November 9, 2026
///
///  Rotation is done in a fixed order shared by the AD and Local methods:
///    1. change the account password (FirstPass / stored password / reset)
///    2. verify the new password against the account
///    3. store it (keychain, then AD for the AD method)
///  Any failure after step 1 reverts the account to the previous password when it
///  is known, so the keychain and the account never disagree (#110, #96).

import Foundation
import OpenDirectory
import Security

/// Keeps SIGTERM / SIGINT / SIGHUP from stopping macOSLAPS between changing the
/// account's password and storing the new one. Being stopped there would leave an
/// account (possibly with a secureToken) on a password nobody has. A request to stop
/// is ignored for those few seconds; the run then finishes normally. launchd's
/// ExitTimeOut (set in the LaunchDaemon) bounds how long a stop can be delayed.
enum CriticalSection {
    private static let signals = [SIGTERM, SIGINT, SIGHUP]
    static func begin() { for s in signals { signal(s, SIG_IGN) } }
    static func end() { for s in signals { signal(s, SIG_DFL) } }
}

class LocalTools: NSObject {
    class func connect() -> ODRecord {
        // Pull Local Administrator Record
        do {
            let local_node = try ODNode.init(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
            let local_admin_record = try local_node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: kODAttributeTypeRecordName)
            return(local_admin_record)
        } catch {
            laps_log.print("Unable to find the local administrator \(Constants.local_admin) (\(describe(error))). Please check that LocalAdminAccount is correct and the account exists.", .error)
            exit(1)
        }
    }
    class func get_expiration_date() -> Date? {
        let (_, creation_date) = KeychainService.loadPassword(service: KeychainNames.current)
        // Convert the date we received to an acceptable format
        if creation_date == nil || creation_date == "Not Found" {
            return(Calendar.current.date(byAdding: .day, value: -7, to: Date()))
        } else {
            guard let formatted_date = Constants.dateFormatter.date(from: creation_date!) else {
                laps_log.print("Unable to read the creation date on the macOSLAPS keychain item. Treating the password as expired.", .warn)
                return(Calendar.current.date(byAdding: .day, value: -7, to: Date()))
            }
            let exp_date = Calendar.current.date(byAdding: .day, value: Constants.days_till_expiration, to: formatted_date)!
            return exp_date
        }
    }

    /// Changes the local admin's password to `newPassword` and verifies it.
    /// Returns the previous password when known (used to revert). Exits on failure.
    class func changeAndVerify(record: ODRecord, to newPassword: String) -> String? {
        let needs_old_password = Determine_secureToken()   // false only when confirmed DISABLED
        let (stored_password, _) = KeychainService.loadPassword(service: KeychainNames.current)
        var previous_password : String? = stored_password
        var source = "the password stored in the keychain"
        if Constants.use_firstpass || stored_password == nil {
            if !Constants.first_password.isEmpty {
                previous_password = Constants.first_password
                source = "the FirstPass value"
            }
        }

        if let old = previous_password {
            // Change with the current password whenever we know it. That keeps a secureToken
            // (and works the same for accounts without one).
            if source == "the FirstPass value" {
                laps_log.print("Performing first password change using the FirstPass value.", .info)
            }
            do {
                try record.changePassword(old, toPassword: newPassword)
            } catch {
                guard !needs_old_password else {
                    laps_log.print("Unable to change the password for \(Constants.local_admin) using \(source) (\(describe(error))). Make sure \(source) is the account's current password.", .error)
                    exit(1)
                }
                // Confirmed no secureToken: the known password is out of date, so a plain reset is safe.
                laps_log.print("\(source.prefix(1).uppercased() + source.dropFirst()) no longer works for \(Constants.local_admin) (\(describe(error))). The account has no secureToken, so resetting it instead.", .warn)
                previous_password = nil
                do {
                    try record.changePassword(nil, toPassword: newPassword)
                } catch {
                    laps_log.print("Unable to reset the password for \(Constants.local_admin) (\(describe(error))).", .error)
                    exit(1)
                }
            }
        } else if needs_old_password {
            laps_log.print("\(Constants.local_admin) has (or may have) a secureToken and there is no stored macOSLAPS password. Set FirstPass in your configuration or run macOSLAPS -firstPass <current password>. Nothing was changed.", .error)
            exit(1)
        } else {
            // Confirmed no secureToken and no known password: a reset as root is safe.
            do {
                try record.changePassword(nil, toPassword: newPassword)
            } catch {
                laps_log.print("Unable to reset the password for \(Constants.local_admin) (\(describe(error))).", .error)
                exit(1)
            }
        }

        do {
            try record.verifyPassword(newPassword)
        } catch {
            laps_log.print("The new password could not be verified for \(Constants.local_admin) (\(describe(error))).", .error)
            _ = revert(record: record, from: newPassword, to: previous_password)
            exit(1)
        }
        return previous_password
    }

    /// Puts the account back on the previous password. Returns true on success.
    class func revert(record: ODRecord, from newPassword: String, to previousPassword: String?) -> Bool {
        guard let previous = previousPassword else {
            laps_log.print("The previous password is unknown, so the change cannot be reverted. Run macOSLAPS -resetPassword again.", .error)
            return false
        }
        do {
            try record.changePassword(newPassword, toPassword: previous)
            laps_log.print("Reverted \(Constants.local_admin) to the previous password.", .warn)
            return true
        } catch {
            laps_log.print("Unable to revert \(Constants.local_admin) to the previous password (\(describe(error))). Reset it with sysadminctl and run macOSLAPS -firstPass <password>.", .error)
            return false
        }
    }

    /// Removes the local admin's login keychain if RemoveKeychain is enabled.
    class func removeAdminKeychainIfEnabled(record: ODRecord) {
        guard Constants.remove_keychain else {
            laps_log.print("RemoveKeychain is off. Logging in as \(Constants.local_admin) may show keychain password prompts.", .warn)
            return
        }
        guard let home = (try? record.values(forAttribute: kODAttributeTypeNFSHomeDirectory))?.first as? String else {
            laps_log.print("Unable to find the home folder for \(Constants.local_admin); keychain not removed.", .warn)
            return
        }
        let keychain_path = home + "/Library/Keychains"
        guard FileManager.default.fileExists(atPath: keychain_path) else {
            laps_log.print("Keychain does not currently exist. This may be due to the fact that the user account has never been logged into and is only used for elevation...", .info)
            return
        }
        do {
            laps_log.print("Removing Keychain for local administrator account \(Constants.local_admin)...", .info)
            try FileManager.default.removeItem(atPath: keychain_path)
        } catch {
            laps_log.print("Unable to remove \(Constants.local_admin)'s Keychain (\(describe(error))). If logging in as this user you may be presented with prompts for keychain", .warn)
        }
    }

    /// Rotates the account. `staged` is the pending password when applying a staged
    /// rotation; otherwise a new password is generated.
    class func password_change(staged: String? = nil) {
        let record = connect()
        let password = staged ?? PasswordGen(length: Constants.password_length)
        CriticalSection.begin()
        if staged != nil { Staging.beginApply() }
        let previous_password = changeAndVerify(record: record, to: password)
        // Test-only: widen the window so CI can send a signal inside it.
        if let pause = ProcessInfo.processInfo.environment["MACOSLAPS_TEST_PAUSE_AFTER_CHANGE"].flatMap(Double.init) {
            Thread.sleep(forTimeInterval: min(pause, 30))
        }

        let save_status : OSStatus = KeychainService.savePassword(service: KeychainNames.current, account: Constants.local_admin, data: password)
        guard save_status == noErr else {
            let message = SecCopyErrorMessageString(save_status, nil) as String? ?? "Unknown error"
            laps_log.print("Unable to save the new password to the keychain (OSStatus \(save_status): \(message)). Reverting.", .error)
            _ = revert(record: record, from: password, to: previous_password)
            exit(1)
        }
        laps_log.print("Password change has been completed locally.", .info)
        Staging.finishApply()
        CriticalSection.end()
        RunState.record("rotated")
        RunState.noteVerified(true, created: KeychainService.loadPassword(service: KeychainNames.current).1)
        removeAdminKeychainIfEnabled(record: record)
        InventoryHook.run(reason: "password change")
    }
}

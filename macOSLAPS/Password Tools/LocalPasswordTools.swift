///
///  LocalPasswordTools.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///
///  Last Update on March 17, 2021

import Foundation
import OpenDirectory

class LocalTools: NSObject {
    class func connect() -> ODRecord {
        // Pull Local Administrator Record
        do {
            let local_node = try ODNode.init(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
            let local_admin_record = try local_node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: kODAttributeTypeRecordName)
            return(local_admin_record)
        } catch {
            laps_log.print("Unable to connect to local directory node using the admin account specified. Please check to make sure the admin account is correct and is available on the system.", .error)
            exit(1)
        }
    }
    class func get_expiration_date() -> Date? {
        let (_, creation_date) = KeychainService.loadPassword(service: "macOSLAPS")
        // Convert the date we received to an acceptable format
        if creation_date == nil {
            return(Calendar.current.date(byAdding: .day, value: -7, to: Date()))
            
        } else {
            guard let formatted_date = Constants.dateFormatter.date(from: creation_date!) else {
                // Print message we were unable to convert the date
                laps_log.print("Unable to unwrap the creation date form our keychain entry. Exiting...", .error)
                exit(1)
            }
            let exp_date = Calendar.current.date(byAdding: .day, value: Constants.days_till_expiration, to: formatted_date)!
            return exp_date
        }
    }
    class func password_change() {
        // Get Configuration Settings
        let security_enabled_user = Determine_secureToken()
        // Generate random password
        let password = PasswordGen(length: Constants.password_length)
        // Pull Local Administrator Record
        guard let local_node = try? ODNode.init(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)) else {
            laps_log.print("Unable to connect to local node.", .error)
            exit(1)
        }
        guard let local_admin_record = try? local_node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: kODAttributeTypeRecordName) else {
            laps_log.print("Unable to retrieve local adminsitrator record.", .error)
            exit(1)
        }
        // Attempt to load password from System Keychain
        let (old_password, _) = KeychainService.loadPassword(service: "macOSLAPS")
        // Password Changing Function
        if security_enabled_user == true {
            // If the attribute is nil then use our first password from config profile to change the password
            if old_password == nil {
                let first_pass = GetPreference(preference_key: "FirstPass") as! String
                do {
                    try local_admin_record.changePassword(first_pass, toPassword: password)
                } catch {
                    laps_log.print("Unable to change password for local administrator \(Constants.local_admin) using FirstPassword Key.", .error)
                    exit(1)
                }
            }
            else {
                // Use the System Keychain password to change the old password to the new one and retain secureToken
                do {
                    try local_admin_record.changePassword(old_password, toPassword: password)
                } catch {
                    laps_log.print("Unable to change password for local administrator \(Constants.local_admin) using password loaded from keychain.", .error)
                    exit(1)
                }
            }
        }
        else {
            // Do the standard reset as FileVault and secureToken are not present
            do {
                try local_admin_record.changePassword(nil, toPassword: password)
            } catch {
                laps_log.print("Unable to reset password for local administrator \(Constants.local_admin).")
            }
        }
        // Write our new password to System Keychain
        let save_status : OSStatus = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: password)
        if save_status == noErr {
            laps_log.print("Password change has been completed locally.", .info)
        } else {
            laps_log.print("We were unable to save the password to keychain so we will revert the changes.", .error)
            do {
                try local_admin_record.changePassword(password, toPassword: old_password)
                exit(1)
            } catch {
                laps_log.print("Unable to revert back to the old password, Please reset the local admin account to the FirstPass key and start again", .error)
                exit(1)
            }
            exit(1)
        }
        
        // Keychain Removal if enabled
        if Constants.remove_keychain == true {
            let local_admin_home = local_admin_record.value(forKeyPath: "dsAttrTypeStandard:NFSHomeDirectory") as! NSMutableArray
            let local_admin_keychain_path = local_admin_home[0] as! String + "/Library/Keychains"
            do {
                if FileManager.default.fileExists(atPath: local_admin_keychain_path) {
                    laps_log.print("Removing Keychain for local administrator account \(Constants.local_admin)...", .info)
                    try FileManager.default.removeItem(atPath: local_admin_keychain_path)
                }
                else {
                    laps_log.print("Keychain does not currently exist. This may be due to the fact that the user account has never been logged into and is only used for elevation...", .info)
                }
            } catch {
                laps_log.print("Unable to remove \(Constants.local_admin)'s Keychain. If logging in as this user you may be presented with prompts for keychain", .warn)
            }
        }
    }
}

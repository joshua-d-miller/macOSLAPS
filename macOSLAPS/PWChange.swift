//
//  PWChange.swift
//  macOSLAPS
//
//  Created by Joshua D. Miller on 6/13/17.
//  The Pennsylvania State University
//  Last Update February 1, 2019

import Foundation
import OpenDirectory

func perform_password_change(computer_record: Array<ODRecord>, local_admin: String) {
    laps_log.print("Password Change is required as the LAPS password for " + local_admin + " has expired", .info)
    // Get our configuration variables to prepare for password change
    
    let pass_length = Int(get_config_settings(preference_key: "PasswordLength") as! Int)
    let exp_days = Int(get_config_settings(preference_key: "DaysTillExpiration") as! Int)
    let keychain_remove = get_config_settings(preference_key: "RemoveKeychain") as! Bool
    
    // Generate random password
    let password = generate_random_pw(length: pass_length)
    do {
        // Pull Local Administrator Record
        let local_node = try ODNode.init(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        let local_admin_record = try local_node.record(withRecordType: kODRecordTypeUsers, name: local_admin, attributes: kODAttributeTypeRecordName)
        // Set out next expiration date in a variable x days from what we specified
        let new_ad_exp_date = time_conversion(time_type: "windows", exp_time: nil, exp_days: exp_days) as! String
        // Format Expiration Date
        let print_exp_date = time_conversion(time_type: "epoch", exp_time: new_ad_exp_date, exp_days: nil) as! Date
        let formatted_new_exp_date = dateFormatter.string(from: print_exp_date)
        // Change the password for the account
        // Check for SecureToken
        let authAuthority = try local_admin_record.values(forAttribute: kODAttributeTypeAuthenticationAuthority) as! [String]
        // If Admin Account has SecureToken
        if authAuthority.contains(";SecureToken;") {
            laps_log.print("This admin user has been detected as having a secureToken. Performing secureToken Password Change...", .info)
            // Attempt to load password from System Keychain
            let old_password = KeychainService.loadPassword(service: "macOSLAPS")
            // If the attribute is nil then use our first password from config profile to change the password
            if old_password == nil {
                let first_pass = get_config_settings(preference_key: "FirstPass") as! String
                try local_admin_record.changePassword(first_pass, toPassword: password)
            }
            // Subsequent password changes after the first one
            else {
                try local_admin_record.changePassword(old_password, toPassword: password)
            }
            // Write our new password to System Keychain
            KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: password)
        }
        else {
            // Do Password change without an old password as there is no SecureToken
            try local_admin_record.changePassword(nil, toPassword: password)
        }

        // Change the password in Active Directory
        _ = ad_tools(computer_record: computer_record, tool: "Set Password", password: password, new_ad_exp_date: new_ad_exp_date)
        laps_log.print("Password change has been completed for local admin " + local_admin + ". New expiration date is " + formatted_new_exp_date, .info)
        if keychain_remove == true {
            let local_admin_home = local_admin_record.value(forKeyPath: "dsAttrTypeStandard:NFSHomeDirectory") as! NSMutableArray
            let local_admin_keychain_path = local_admin_home[0] as! String + "/Library/Keychains"
            do {
                if FileManager.default.fileExists(atPath: local_admin_keychain_path) {
                    laps_log.print("Removing Keychain for local administrator account " + local_admin + "...", .info)
                    try FileManager.default.removeItem(atPath: local_admin_keychain_path)
                }
                else {
                    laps_log.print("Keychain does not currently exist. This may be due to the fact that the user account has never been logged into and is only used for elevation...", .info)
                }
            } catch {
                laps_log.print("Unable to remove " + local_admin + "'s Keychain.", .error)
                exit(1)
            }
        }
        else {
            laps_log.print("Keychain has NOT been modified. Keep in mind that this may cause keychain prompts and the old password may not be accessible.", .warn)
            exit(1)
        }
    } catch {
        laps_log.print("Unable to connect to local directory or change password. Exiting...", .error)
        exit(1)
    }
}

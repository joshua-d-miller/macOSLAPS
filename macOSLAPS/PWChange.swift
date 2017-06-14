//
//  PWChange.swift
//  macOSLAPS
//
//  Created by Joshua D. Miller on 6/13/17.
//  The Pennsylvania State University
//

import Foundation
import OpenDirectory

func perform_password_change(computer_record: Array<ODRecord>, local_admin: String) {
    laps_log.print("Password Change is required as the LAPS password for " + local_admin + " has expired", .info)
    // Get our configuration variables to prepare for password change
    let pass_length = get_config_settings(preference_key: "PasswordLength") as! Int
    let exp_days = get_config_settings(preference_key: "DaysTillExpiration") as! Int
    let keychain_remove = get_config_settings(preference_key: "RemoveKeychain") as! Bool
    // Generate random password
    let password = generate_random_pw(length: pass_length)
    do {
        // Pull Local Administrator Record
        let local_node = try ODNode.init(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        let local_admin_change = try local_node.record(withRecordType: kODRecordTypeUsers, name: local_admin, attributes: nil)
        // Change the password for the account
        try local_admin_change.changePassword(nil, toPassword: password)
        // Set out nex expiration date in a variable x days from our
        // configuration variable
        let new_ad_exp_date = time_conversion(time_type: "windows", exp_time: nil, exp_days: exp_days) as! String
        // Format Expiration Date
        let print_exp_date = time_conversion(time_type: "epoch", exp_time: new_ad_exp_date, exp_days: nil) as! Date
        let formatted_new_exp_date = dateFormatter.string(from: print_exp_date)
        // Change the password in Active Directory
        _ = ad_tools(computer_record: computer_record, tool: "Set Password", password: password, new_ad_exp_date: new_ad_exp_date)
        laps_log.print("Password change has been completed for local admin " + local_admin + ". New expiration date is " + formatted_new_exp_date, .info)
    } catch {
        laps_log.print("Unable to connect to local directory or change password. Exiting...", .error)
        exit(1)
    }
    if keychain_remove == true {
        let local_admin_path = "/Users/" + local_admin + "/Library/Keychains"
        do {
            if FileManager.default.fileExists(atPath: local_admin_path) {
                laps_log.print("Removing Keychain for local administrator account " + local_admin + "...", .info)
                try FileManager.default.removeItem(atPath: local_admin_path)
            }
            else {
                laps_log.print("Keychain does not currently exist. This may be due to the fact that the user account has never been logged into and is only used for elevation...")
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
}

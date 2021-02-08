///
///  PasswordChange.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///  The Pennsylvania State University
///  Last Update February 7, 2021

import Cocoa
import Foundation
import OpenDirectory


// Set up a function to run bash commands so we
// can run fdesetup - From StackOverflow
// https://stackoverflow.com/questions/26971240/how-do-i-run-an-terminal-command-in-a-swift-script-e-g-xcodebuild
func shell(launchPath: String, arguments: [String]) -> String
{
    let task = Process()
    task.launchPath = launchPath
    task.arguments = arguments
    
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.launch()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: String.Encoding.utf8)!
    if output.count > 0 {
        //remove newline character.
        let lastIndex = output.index(before: output.endIndex)
        return String(output[output.startIndex ..< lastIndex])
    }
    return output
}

// Password Change Class that can be used to perform the password change either using Active Directory
// or a local method. Both methods will save the password for keychain in case of secureToken

class PasswordChange: NSObject {
    class func Determine_secureToken(local_admin: String) -> Bool {
        /* --- Change the password for the account --- */
        // Check OS Version as that will determine how we proceed
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion.init(majorVersion: 10, minorVersion: 13, patchVersion: 0)) {
            // Check for secureToken
            let secure_token_status = shell(launchPath: "/usr/sbin/sysadminctl", arguments: ["-secureTokenStatus", local_admin])
            if secure_token_status.contains("ENABLED") {
                laps_log.print("The local admin: \(local_admin) has been detected to have a secureToken. Performing secure password change...", .info)
                return(true)
            }
            else {
                return(false)
            }
        }
        else {
            // Determine if FileVault is Enabled
            let fv_status = shell(launchPath: "/usr/bin/fdesetup", arguments: ["status"])
            if (fv_status.contains("FileVault is On.")) {
            // Check if Local Admin is a FileVault User
                let fv_user_cmd = shell(launchPath: "/usr/bin/fdesetup", arguments: ["list"])
                let fv_user_list = fv_user_cmd.components(separatedBy: [",", "\n"])
                // Is Our Admin User a FileVault User?
                if (fv_user_list.contains(local_admin)) {
                    laps_log.print("The local admin: \(local_admin) is currently a FileVault user. Performing secure password change...", .info)
                    return(true)
                }
                else {
                    return(false)
                }
            }
            else {
                return(false)
            }
        }
    }
    class func AD(computer_record: Array<ODRecord>) {
        let security_enabled_user = Determine_secureToken(local_admin: Constants.local_admin)
        // Generate random password
        let password = PasswordGen(length: Constants.password_lenth)
        
        do {
            // Pull Local Administrator Record
            let local_node = try ODNode.init(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
            let local_admin_record = try local_node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: kODAttributeTypeRecordName)
            
            // Set out next expiration date in a variable x days from what we specified
            let new_ad_exp_date = TimeConversion.windows()
            
            // Format Expiration Date
            let print_exp_date = TimeConversion.epoch(exp_time: new_ad_exp_date!)
            let formatted_new_exp_date = Constants.dateFormatter.string(from: print_exp_date!)
            
            // Attempt to load password from System Keychain
            let (old_password, _) = KeychainService.loadPassword(service: "macOSLAPS")
            // Have we determineed that the local admin is a FileVault User or that the local admin user has a secureToken?
            if security_enabled_user == true {
                // If the attribute is nil then use our first password from config profile to change the password
                if old_password == nil {
                    let first_pass = GetPreference(preference_key: "FirstPass") as! String
                    try local_admin_record.changePassword(first_pass, toPassword: password)
                }
                else {
                    // Use the System Keychain password to change the old password to the new one and retain secureToken
                    try local_admin_record.changePassword(old_password, toPassword: password)
                }
            }
            else {
                // Do the standard reset as FileVault and secureToken are not present
                try local_admin_record.changePassword(nil, toPassword: password)
            }
            // Write our new password to System Keychain
            _ = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: password)
            
            // Change the password in Active Directory
            let write_pw_status = ADTools.set_password(computer_record: computer_record, password: password, new_ad_exp_date: new_ad_exp_date!)
            // Error catching should the Writing of the password fail. Revert the changes and exit
            if write_pw_status == "Failure" {
                try local_admin_record.changePassword(password, toPassword: old_password)
                // Write our old password back to System Keychain
                _ = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: old_password!)
                laps_log.print("Since the Password or Expiration Time was unable to be written back to Active Directory, changes have been reverted and the application will now exit", .error)
                exit(1)
            }
            
            laps_log.print("Password change has been completed for the local admin \(Constants.local_admin). New expiration date is \(formatted_new_exp_date)", .info)
            
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
                    laps_log.print("Unable to remove \(Constants.local_admin)'s Keychain.", .error)
                    exit(1)
                }
            }
            else {
                laps_log.print("Keychain has NOT been modified. Keep in mind that this may cause keychain prompts and the old password may not be accessible.", .warn)
                exit(1)
            }
        // Throw an error if we for some reason cannot connect to the Local Directory to perform the password change
        } catch {
            laps_log.print("Unable to connect to local directory or change password. Exiting...", .error)
            exit(1)
        }
    }
    class func Local() {
        // Get Configuration Settings
        let security_enabled_user = Determine_secureToken(local_admin: Constants.local_admin)
        // Generate random password
        let password = PasswordGen(length: Constants.password_lenth)
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
        _ = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: password)
        
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
                laps_log.print("Unable to remove \(Constants.local_admin)'s Keychain.", .error)
                exit(1)
            }
        }
        
        
    }
}

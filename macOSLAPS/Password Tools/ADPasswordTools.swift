///
///  ADPasswordTools.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///  The Pennsylvania State University
///  Last Update on March 17, 2021

import Foundation
import OpenDirectory
import SystemConfiguration

// Tools that will allow for passwords to be read
// and written to Active Directory (Usually the default

public class ADTools: NSObject {

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
            let query = try! ODQuery.init(node: node, forRecordTypes: [kODRecordTypeServer, kODRecordTypeComputers], attribute: kODAttributeTypeRecordName, matchType: UInt32(kODMatchEqualTo), queryValues: adDict!["TrustAccount"], returnAttributes: kODAttributeTypeNativeOnly, maximumResults: 0)
            computer_record = try! query.resultsAllowingPartial(false) as! [ODRecord]
        }
        catch {
            laps_log.print("Active Directory Node not available. Make sure your Active Directory is reachable via direct network connection or VPN.", .error)
            exit(1)
        }
        return(computer_record)
    }
    class func check_pw_expiration(computer_record: Array<ODRecord>) -> String? {
        var expirationtime: Any
            expirationtime = "126227988000000000" // Setting a default expiration date of 01/01/2001
        do {
            expirationtime = try computer_record[0].values(forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")[0]
        } catch {
            laps_log.print("There has never been a random password generated for this device. Setting a default expiration date of 01/01/2001 in Active Directory to force a password change...", .warn)
        }
        return(expirationtime) as? String
    }
    class func verify_dc_writability(computer_record: Array<ODRecord>) {
        // Test that we can write to the domain controller we are currently connected to
        // before actually attemtping to write the new password
        do {
            let expirationtime = try? computer_record[0].values(forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")
            if expirationtime == nil {
                try computer_record[0].setValue("Th1sIsN0tth3P@ssword", forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwd")
            }
            else {
                try computer_record[0].setValue(expirationtime, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")
            }
        } catch {
            laps_log.print("Unable to test setting the current expiration time in Active Directory to the same value. Either the record is not writable or the domain controller is not writable.", .error)
            exit(1)
        }
    }
    class func password_change(computer_record: Array<ODRecord>) {
        let security_enabled_user = Determine_secureToken()
        // Generate random password
        let password = PasswordGen(length: Constants.password_lenth)
        // Set out next expiration date in a variable x days from what we specified
        let new_ad_exp_date = TimeConversion.windows()
        // Format Expiration Date
        let print_exp_date = TimeConversion.epoch(exp_time: new_ad_exp_date!)
        let formatted_new_exp_date = Constants.dateFormatter.string(from: print_exp_date!)
        // Attempt to load password from System Keychain
        let (old_password, _) = KeychainService.loadPassword(service: "macOSLAPS")
        // Connect to local node in order to change the password locally
        guard let local_node = try? ODNode.init(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)) else {
            laps_log.print("Unable to connect to local node.", .error)
            exit(1)
        }
        guard let local_admin_record = try? local_node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: kODAttributeTypeRecordName) else {
            laps_log.print("Unable to retrieve local adminsitrator record.", .error)
            exit(1)
        }
        // Have we determineed that the local admin is a FileVault User or that the local admin user has a secureToken?
        if security_enabled_user == true {
            // If the attribute is nil then use our first password from config profile to change the password
            if old_password == nil {
                do {
                    laps_log.print("Performing first password change using FirstPass attribute from configuration.", .info)
                    try local_admin_record.changePassword(Constants.first_password, toPassword: password)
                } catch {
                    laps_log.print("Unable to perform the first password change for secureToken admin account \(Constants.local_admin).")
                    exit(1)
                }
            }
            else {
                do {
                    laps_log.print("Performing password change using stored keychain item.", .info)
                    // Use the System Keychain password to change the old password to the new one and retain secureToken
                    try local_admin_record.changePassword(old_password, toPassword: password)
                } catch {
                    laps_log.print("Unable to perform password change using keychain item. The keychain item might have the wrong password stored.", .error)
                    exit(1)
                }
            }
        }
        else {
            do {
                // Do the standard reset as FileVault and secureToken are not present
                try local_admin_record.changePassword(nil, toPassword: password)
            } catch {
                laps_log.print("Unable to reset password for \(Constants.local_admin). Please make sure we are able to write to the local record and perform the password change.", .error)
            }
        }
        // Write our new password to System Keychain and Active Directory
        var save_status : OSStatus
        save_status = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: password)
        // Error Catching for writing to keychain
        if save_status == noErr {
            laps_log.print("Password change has been completed locally. Performing changes to Active Directory", .info)
        }
        else {
            do {
                laps_log.print("New Password could not be saved to the keychain. Reverting Changes and exiting...", .error)
                try local_admin_record.changePassword(password, toPassword: old_password)
                exit(1)
            } catch {
                laps_log.print("Unable to revert back to the old password, Please reset the local admin account to the FirstPass key and start again", .error)
                exit(1)
            }
        }
        save_status = ADTools.set_password(computer_record: computer_record, password: password, new_ad_exp_date: new_ad_exp_date!)
        // Error catching should the Writing of the password fail. Revert the changes and exit
        if save_status != 0 {
            do {
                try local_admin_record.changePassword(password, toPassword: old_password)
                // Write our old password back to System Keychain
                _ = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: old_password!)
                laps_log.print("Since the Password or Expiration Time was unable to be written back to Active Directory, changes have been reverted and the application will now exit", .error)
                exit(1)
            } catch {
                laps_log.print("Unable to revert the changes. In order to restore functionality it is recommended that sysadminctl be used to reset the password to either the keychain password or the FirstPass atrribute for \(Constants.local_admin).", .error)
                exit(1)
            }
        }
        
        laps_log.print("Password change has been written to Active Directory for the local admin \(Constants.local_admin). The new expiration date is \(formatted_new_exp_date)", .info)
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
        else {
            laps_log.print("Keychain has NOT been modified. Keep in mind that this may cause keychain prompts and the old password may not be accessible.", .warn)
            exit(1)
        }
        // Throw an error if we for some reason cannot connect to the Local Directory to perform the password change
    }
    class func set_password(computer_record: Array<ODRecord>, password: String, new_ad_exp_date: String) -> OSStatus {
        do {
            try computer_record[0].setValue(password, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwd")
        } catch {
            laps_log.print("There was an error setting the password for this device...", .error)
            return(1)
        }
        
        do {
            try computer_record[0].setValue(new_ad_exp_date, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")
        } catch {
            laps_log.print("There was an error setting the new password expiration for this device...", .warn)
            return(2)
        }
        return(0)
    }
}

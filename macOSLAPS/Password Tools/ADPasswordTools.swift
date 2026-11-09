///
///  ADPasswordTools.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///  
///  Last Update on February 21, 2024

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
        // Generate random password
        let password = PasswordGen(length: Constants.password_length)
        // Set out next expiration date in a variable x days from what we specified
        let new_ad_exp_date = TimeConversion.windows()
        // Format Expiration Date
        let print_exp_date = TimeConversion.epoch(exp_time: new_ad_exp_date!)
        let formatted_new_exp_date = Constants.dateFormatter.string(from: print_exp_date!)
        // Change and verify the local password (shared with the Local method)
        let local_admin_record = LocalTools.connect()
        let previous_password = LocalTools.changeAndVerify(record: local_admin_record, to: password)

        // Write our new password to the System Keychain
        let save_status = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: password)
        guard save_status == noErr else {
            laps_log.print("New password could not be saved to the keychain (OSStatus \(save_status)). Reverting changes and exiting...", .error)
            _ = LocalTools.revert(record: local_admin_record, from: password, to: previous_password)
            exit(1)
        }
        laps_log.print("Password change has been completed locally. Performing changes to Active Directory", .info)

        // Write to Active Directory. On failure, put the account and keychain back.
        if ADTools.set_password(computer_record: computer_record, password: password, new_ad_exp_date: new_ad_exp_date!) != 0 {
            if LocalTools.revert(record: local_admin_record, from: password, to: previous_password), let previous = previous_password {
                _ = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: previous)
                laps_log.print("Since the Password or Expiration Time was unable to be written back to Active Directory, changes have been reverted and the application will now exit", .error)
            } else {
                laps_log.print("Active Directory could not be updated and the local change could not be reverted. The keychain holds the current password; run macOSLAPS -resetPassword once Active Directory is reachable.", .error)
            }
            exit(1)
        }

        laps_log.print("Password change has been written to Active Directory for the local administrator \(Constants.local_admin). The new expiration date is \(formatted_new_exp_date)", .info)
        LocalTools.removeAdminKeychainIfEnabled(record: local_admin_record)
    }
    class func set_password(computer_record: Array<ODRecord>, password: String, new_ad_exp_date: String) -> OSStatus {
        do {
            try computer_record[0].setValue(password, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwd")
        } catch {
            laps_log.print("There was an error setting the password for this device (\(describe(error)))", .error)
            return(1)
        }
        
        do {
            try computer_record[0].setValue(new_ad_exp_date, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")
        } catch {
            laps_log.print("There was an error setting the new password expiration for this device (\(describe(error)))", .warn)
            return(2)
        }
        return(0)
    }
}

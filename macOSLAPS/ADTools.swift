///
///  ADTools.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///  The Pennsylvania State University
///  Last Update on February 1, 2021

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
    class func set_password(computer_record: Array<ODRecord>, password: String, new_ad_exp_date: String) -> String {
        do {
            try computer_record[0].setValue(password, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwd")
        } catch {
            laps_log.print("There was an error setting the password for this device...", .error)
            return("Failure")
        }
        
        do {
            try computer_record[0].setValue(new_ad_exp_date, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")
        } catch {
            laps_log.print("There was an error setting the new password expiration for this device...", .warn)
            return("Failure")
        }
        return("Success")
    }
}

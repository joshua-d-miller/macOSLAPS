//
//  ADTools.swift
//  macOSLAPS
//
//  Created by Joshua D. Miller on 6/13/17.
//  The Pennsylvania State University
//  Last Update on 03/09/18

import Foundation
import OpenDirectory
import SystemConfiguration

// Determine the password expiration time for the computer account in Active Directory
func connect_to_ad() -> Array<ODRecord> {
    // Connect to Active Directory
    // Create Net Config
    let net_config = SCDynamicStoreCreate(nil, "net" as CFString, nil, nil)
    // Get Active Directory Info
    let ad_info = [ SCDynamicStoreCopyValue(net_config, "com.apple.opendirectoryd.ActiveDirectory" as CFString)]
    // Convert ad_info variable to dictionary as it seems there is support for multiple directories
    let adDict = ad_info[0] as? NSDictionary ?? nil
    if adDict == nil {
        laps_log.print("This machine does not appear to be bound to Active Directory")
        exit(1)
    }
    // Use Open Directory to Connect to Active Directory
    let session = ODSession.default()
    // Create the Active Directory Path in case Search Paths are disabled
    let ad_path = "\(adDict?["NodeName"] as! String)/\(adDict?["DomainNameDns"] as! String)"
    var computer_record = [ODRecord]()
    do {
        let node = try ODNode.init(session: session, name: ad_path)
        let query = try! ODQuery.init(node: node, forRecordTypes: [kODRecordTypeServer, kODRecordTypeComputers], attribute: kODAttributeTypeRecordName, matchType: UInt32(kODMatchEqualTo), queryValues: adDict?["TrustAccount"], returnAttributes: kODAttributeTypeNativeOnly, maximumResults: 0)
        computer_record = try! query.resultsAllowingPartial(false) as! [ODRecord]
    }
    catch {
        laps_log.print("Active Directory Node not available. Make sure your Active Directory is reachable via direct network connection or VPN.", .error)
        exit(1)
    }
    return(computer_record)
}

// Active Directory Tools that will get our expiration time or set a new one
// and change the password listed in AD
func ad_tools(computer_record: Array<ODRecord>, tool: String, password: String?, new_ad_exp_date: String?) -> String? {
    for case let value in computer_record {
        if tool == "Expiration Time" {
            var expirationtime = "126227988000000000" // Setting a default expiration date of 01/01/2001
            do {
                expirationtime = try String(describing: value.values(forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")[0])
                // Test that the computer record is writable
                do {
                    try value.setValue(expirationtime, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")
                } catch {
                    laps_log.print("Unable to test setting the current expiration time in Active Directory to the same value. Either the record is not writable or the domain controller is not writable.", .error)
                    exit(1)
                }
            } catch {
                laps_log.print("There has never been a random password generated for this device. Setting a default expiration date of 01/01/2001 in Active Directory to force a password change...", .warn)
            }
            return(expirationtime)
        }

        if tool == "Set Password" {
            // Test that we can write to the domain controller we are currently connected to
            // before actually attemtping to write the new password
            do {
                
                try value.setValue(password, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwd")
            } catch {
                laps_log.print("There was an error setting the password for this device...", .error)
                exit(1)
            }
            
            do {
                try value.setValue(new_ad_exp_date, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")
            } catch {
                laps_log.print("There was an error setting the new password expiration for this device...", .warn)
            }
        }
    }
    return(nil)
}

//
//  ADTools.swift
//  macOSLAPS
//
//  Created by Joshua D. Miller on 6/13/17.
//  The Pennsylvania State University
//

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
    let adDict = ad_info[0]! as! NSDictionary
    // Use Open Directory to Connect to Active Directory
    let session = ODSession.default()
    var computer_record = [ODRecord]()
    let node = try! ODNode.init(session: session, type:UInt32(kODNodeTypeNetwork))
    let query = try! ODQuery.init(node: node, forRecordTypes: kODRecordTypeComputers, attribute: kODAttributeTypeRecordName, matchType: UInt32(kODMatchEqualTo), queryValues: adDict["TrustAccount"], returnAttributes: kODAttributeTypeNativeOnly, maximumResults: 0)
    computer_record = try! query.resultsAllowingPartial(false) as! [ODRecord]
    if computer_record.isEmpty {
        laps_log.print("Unable to connect to Active Directory", .error)
        exit(1)
    }
    return(computer_record)
}

// Active Directory Tools that will get our expiration time or set a new one
// and change the password listed in AD
func ad_tools(computer_record: Array<ODRecord>, tool: String, password: String?, new_ad_exp_date: String?) -> String? {
    for case let value in computer_record {
        if tool == "Expiration Time" {
            var expirationtime = try! String(describing: value.values(forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")[0])
            if !expirationtime.isEmpty {
                return(expirationtime)
            }
            else {
                laps_log.print("There has never been a random password generated for this device. Setting a default expiration date of 01/01/2001 in Active Directory to force a password change...", .warn)
                expirationtime = "126227988000000000"
                return(expirationtime)
            }
        }
        if tool == "Set Password" {
            try! value.setValue(password, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwd")
            try! value.setValue(new_ad_exp_date, forAttribute: "dsAttrTypeNative:ms-Mcs-AdmPwdExpirationTime")
        }
    }
    return(nil)
}

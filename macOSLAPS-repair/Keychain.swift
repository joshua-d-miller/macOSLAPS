//
//  Keychain.swift
//  macOSLAPS - Pulled from LAPS for macOS to use with System.keychain
//
//  Created by Joshua D. Miller on 7/21/18.
//  The Pennsylvania State University
//  Sources: https://stackoverflow.com/a/37539998/1694526
//  https://developer.apple.com/documentation/security/keychain_services/keychain_items/searching_for_keychain_items
//  https://gitlab.com/orchardandgrove-oss/NoMADLogin-AD/blob/master/Mechs/KeychainAdd.swift
//  Unlocking System Keychain code inspired by NoMad Login - Thanks Joel Rennich
//  Another special thanks to Joel for critiqing my code to figure out the keychain function needed rewrote to compile in Xcode 11.1
//  Last Updated February 2, 2021

import Cocoa
import Security

class KeychainService {
    
    class func updatePerm()-> OSStatus {
        var systemKeychain : SecKeychain?
        SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain)
        SecKeychainSetUserInteractionAllowed(false)
                defer { SecKeychainSetUserInteractionAllowed(true) }
        
        var access : SecAccess?
        var trustedappSelf: SecTrustedApplication?
        var trustedappRepair: SecTrustedApplication?
        
        SecTrustedApplicationCreateFromPath("/usr/local/laps/macOSLAPS", &trustedappSelf)
        SecTrustedApplicationCreateFromPath(nil, &trustedappRepair)
        
        let trustedList = [trustedappSelf, trustedappRepair]
        
        SecAccessCreate("macOSLAPS Access" as CFString, trustedList as CFArray, &access)
        
        let query : [String : Any] = [
            kSecClass as String            : kSecClassGenericPassword,
            kSecAttrService as String      : "macOSLAPS",
            kSecReturnData as String       : kCFBooleanTrue!,
            kSecReturnAttributes as String : kCFBooleanTrue!,
            kSecMatchLimit as String       : kSecMatchLimitOne,
            kSecUseKeychain as String      : systemKeychain!]

        var item: AnyObject? = nil
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if status == noErr {
            let existingItem = item as? [String: Any]
            let passwordData = existingItem![String(kSecValueData)] as? Data
            let password = String(data: passwordData!, encoding: String.Encoding.utf8)
            let creationdate = existingItem![String(kSecAttrCreationDate)]
            let dataFromString = password!.data(using: String.Encoding.utf8, allowLossyConversion: false)
            SecItemDelete(query as CFDictionary)
            let new_entry : [String : Any] = [
                kSecClass as String             : kSecClassGenericPassword as String,
                kSecAttrService as String       : "macOSLAPS",
                kSecAttrAccess as String        : access!,
                kSecAttrAccount as String       : "LAPS Password",
                kSecAttrCreationDate as String  : creationdate as! CFDate,
                kSecValueData as String         : dataFromString!,
                kSecUseKeychain as String       : systemKeychain!]
            let code : OSStatus = SecItemAdd(new_entry as CFDictionary, nil)
            return(code)
        }
        return(status)
    }
}

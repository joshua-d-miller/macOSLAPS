///
///  KeychainService.swift
///  macOSLAPS - Pulled from LAPS for macOS to use with System.keychain
///
///  Created by Joshua D. Miller on 7/21/18.
///
///  Sources: https://stackoverflow.com/a/37539998/1694526
///  https://developer.apple.com/documentation/security/keychain_services/keychain_items/searching_for_keychain_items
///  https://gitlab.com/orchardandgrove-oss/NoMADLogin-AD/blob/master/Mechs/KeychainAdd.swift
///  Unlocking System Keychain code inspired by NoMad Login - Thanks Joel Rennich
///  Another special thanks to Joel for critiqing my code to figure out the keychain function needed rewrote to compile in Xcode 11.1
///  Last Updated Feb 26, 2024

import Cocoa
import Security
@available(macOS, introduced: 10.2, deprecated: 10.10, message: "SecKeychain, SecTrustedApplicationCreateFromPath and SecAccessCreate are all deprecated but still currently work as of macOS 14 (Sonoma)[2024]")
class KeychainService {
    class func savePassword(service: String, account: String, data: String) -> OSStatus {
        let dataFromString = data.data(using: String.Encoding.utf8, allowLossyConversion: false)
        var systemKeychain : SecKeychain?
        
        SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain)
        SecKeychainUnlock(systemKeychain, 0, nil, false)
        
        // The query used to save our newly created keychain entry
        let query : [String : Any] = [
            kSecClass as String        : kSecClassGenericPassword as String,
            kSecAttrService as String  : service,
            kSecAttrAccount as String  : account,
            kSecValueData as String    : dataFromString!,
            kSecUseKeychain as String  : systemKeychain!]
        
        // Remove old keychain entry
        SecItemDelete(query as CFDictionary)
        // Create new keychain entry
        SecItemAdd(query as CFDictionary, nil)
        
        // Add Creation Date as Comment
        // This seemed to require another query and update as it failed with the original
        let creation_date = Constants.dateFormatter.string(from: Date())
        let newquery : [ String : Any ] = [
            kSecClass as String       : kSecClassGenericPassword,
            kSecAttrService as String : service,
            kSecUseKeychain as String : systemKeychain!]
        let comment_attribute : [ String : Any ] = [
            kSecAttrComment as String : "Created: \(creation_date)"
        ]
        return SecItemUpdate(newquery as CFDictionary, comment_attribute as CFDictionary)
    }
    
    class func loadPassword(service: String) -> (String?, String?) {
        // Instantiate a new default keychain query
        // Tell the query to return a result
        var systemKeychain : SecKeychain?
        
        SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain)
        SecKeychainUnlock(systemKeychain, 0, nil, false)
        
        let query : [String : Any] = [
            kSecClass as String            : kSecClassGenericPassword,
            kSecAttrService as String      : service,
            kSecReturnData as String       : kCFBooleanTrue!,
            kSecReturnAttributes as String : kCFBooleanTrue!,
            kSecMatchLimit as String       : kSecMatchLimitOne,
            kSecUseKeychain as String      : systemKeychain!]
        
        var item: AnyObject? = nil
        SecKeychainSetUserInteractionAllowed(false)
                defer { SecKeychainSetUserInteractionAllowed(true) }
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if status == noErr {
            let existingItem = item as? [String: Any]
            let passwordData = existingItem![String(kSecValueData)] as? Data
            let password = String(data: passwordData!, encoding: String.Encoding.utf8)
            guard let comment = existingItem?[String(kSecAttrComment)] as? String else {
                laps_log.print("There is currently no expriation date comment", .warn)
                return(password, nil)
            }
            let r = comment.index(comment.startIndex, offsetBy: 9)..<comment.endIndex
            let creationdate = String(comment[r])
            
            return (password, creationdate)
        } else if status == -25300 {
            // macOSLAPS Keychain Entry Not Found
            return(nil, "Not Found")
        }
        return(nil,nil)
    }
    class func exportPassword(service: String, account: String, data: String, expiration: String) -> OSStatus {
        let dataFromString = data.data(using: String.Encoding.utf8, allowLossyConversion: false)
        var systemKeychain : SecKeychain?
        
        SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain)
        SecKeychainUnlock(systemKeychain, 0, nil, false)
        
        // Create access for our two binaries to access the Keychain
        // Item. This shold ensure we always have access
        var access : SecAccess?
        var trustedappSelf: SecTrustedApplication?
        var trustedappSecurity: SecTrustedApplication?
        var trustedList : Array<SecTrustedApplication?>
        
        SecTrustedApplicationCreateFromPath(nil, &trustedappSelf)
        SecTrustedApplicationCreateFromPath("/usr/bin/security", &trustedappSecurity)
        
        // Error Checking for if some reason the repair is not available
        if trustedappSelf != nil && trustedappSecurity != nil {
            trustedList = [trustedappSelf, trustedappSecurity]
        } else {
            trustedList = [trustedappSelf]
        }
        
        // Create Access list with our applications
        SecAccessCreate("macOSLAPS Access" as CFString, trustedList as CFArray, &access)
        
        // The query used to save our newly created keychain entry
        let query : [String : Any] = [
            kSecClass as String        : kSecClassGenericPassword as String,
            kSecAttrService as String  : service,
            kSecAttrAccount as String  : account,
            kSecAttrAccess as String   : access!,
            kSecValueData as String    : dataFromString!,
            kSecUseKeychain as String  : systemKeychain!]

        // Create new keychain entry
        SecItemAdd(query as CFDictionary, nil)
        
        // Add Creation Date as Comment
        // This seemed to require another query and update as it failed with the original
        let newquery : [ String : Any ] = [
            kSecClass as String       : kSecClassGenericPassword,
            kSecAttrService as String : service,
            kSecUseKeychain as String : systemKeychain!]
        let comment_attribute : [ String : Any ] = [
            kSecAttrComment as String : "Created: \(expiration)"
        ]
        return SecItemUpdate(newquery as CFDictionary, comment_attribute as CFDictionary)
    }
    class func deleteExport(service: String) -> OSStatus {
        var systemKeychain : SecKeychain?
        
        SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain)
        SecKeychainUnlock(systemKeychain, 0, nil, false)
    
        // The query used to save our newly created keychain entry
        let query : [String : Any] = [
            kSecClass as String            : kSecClassGenericPassword,
            kSecAttrService as String      : service,
            kSecReturnData as String       : kCFBooleanTrue!,
            kSecReturnAttributes as String : kCFBooleanTrue!,
            kSecMatchLimit as String       : kSecMatchLimitOne,
            kSecUseKeychain as String      : systemKeychain!]
        return SecItemDelete(query as CFDictionary)
    }
}

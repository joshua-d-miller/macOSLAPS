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
//  Last Updated February 1, 2019

import Cocoa
import Security


// Arguments for the keychain queries
let kSecClassValue = NSString(format: kSecClass)
let kSecAttrAccountValue = NSString(format: kSecAttrAccount)
let kSecValueDataValue = NSString(format: kSecValueData)
let kSecClassGenericPasswordValue = NSString(format: kSecClassGenericPassword)
let kSecAttrServiceValue = NSString(format: kSecAttrService)
let kSecMatchLimitValue = NSString(format: kSecMatchLimit)
let kSecReturnDataValue = NSString(format: kSecReturnData)
let kSecMatchLimitOneValue = NSString(format: kSecMatchLimitOne)
let kSecUseKeychainValue = NSString(format: kSecUseKeychain)

public class KeychainService: NSObject {
    
    class func savePassword(service: String, account:String, data: String) {
        if let dataFromString = data.data(using: String.Encoding.utf8, allowLossyConversion: false) {
            var systemKeychain : SecKeychain?
            
            SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain)
            SecKeychainUnlock(systemKeychain, 0, nil, false)
            
            // Instantiate a new default keychain query
            let keychainQuery: NSMutableDictionary = NSMutableDictionary(
                objects: [systemKeychain as Any, kSecClassGenericPasswordValue, service, account, dataFromString],
                forKeys: [kSecUseKeychainValue, kSecClassValue, kSecAttrServiceValue, kSecAttrAccountValue, kSecValueDataValue])
            
            // Add the new keychain item
            var status = SecItemAdd(keychainQuery as CFDictionary, nil)
            
            while status != 0 {
                SecItemDelete(keychainQuery as CFDictionary)
                status = SecItemAdd(keychainQuery as CFDictionary, nil)
            }
        }
    }
    
    class func loadPassword(service: String) -> String? {
        // Instantiate a new default keychain query
        // Tell the query to return a result
        var systemKeychain : SecKeychain?
        
        SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain)
        SecKeychainUnlock(systemKeychain, 0, nil, false)
        
        let keychainQuery: NSMutableDictionary = NSMutableDictionary(
            objects: [systemKeychain as Any, kSecClassGenericPassword, service, kCFBooleanTrue ?? false, kCFBooleanTrue ?? false, kSecMatchLimitOne],
            forKeys: [kSecUseKeychainValue, kSecClass, kSecAttrServiceValue, kSecReturnData, kSecReturnAttributes, kSecMatchLimit])
        
        var item: CFTypeRef?
        
        // Search for the keychain items
        let status: OSStatus = SecItemCopyMatching(keychainQuery, &item)
        var password: String? = nil
        
        if status == errSecSuccess {
            if let existingItem = item as? [String:Any] {
                // Get Password Data
                let passwordData = existingItem[kSecValueData as String] as? Data
                password = String(data: passwordData!, encoding: String.Encoding.utf8)
            }
        } else {
            // We are commenting this out to keep it out of the log.
            // print("Nothing was retrieved from the keychain. Status code \(status)")
            return(nil)
        }
        
        return(password)
    }
}

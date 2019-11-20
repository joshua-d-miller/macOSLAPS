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
//  Last Updated November 7, 2019

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
            let keychainQuery : [ String : AnyObject ] = [
            kSecUseKeychainValue as String : systemKeychain as AnyObject,
            kSecClassValue as String : kSecClassGenericPasswordValue as AnyObject,
            kSecAttrServiceValue as String: service as AnyObject,
            kSecAttrAccountValue as String : account as AnyObject,
            kSecValueDataValue as String : dataFromString as AnyObject]
            
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
        
        let keychainQuery : [ String : AnyObject ] = [
        kSecReturnAttributes as String: true as AnyObject,
        kSecReturnData as String : true as AnyObject,
        kSecMatchLimit as String : kSecMatchLimitOne as AnyObject,
        kSecAttrServiceValue as String : service as AnyObject,
        kSecClass as String : kSecClassGenericPassword as AnyObject,
        kSecUseKeychainValue as String : systemKeychain as AnyObject]
        
        var item: CFTypeRef?
        
        // Search for the keychain items
        let status: OSStatus = SecItemCopyMatching(keychainQuery as CFDictionary, &item)
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

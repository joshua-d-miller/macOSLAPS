/*
===============================================================================
 macOSLAPS | Extensions | KeychainService.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2018-07-21
 Updated:   2026-11-11

 Purpose:
     Stores the password in the System keychain. A root launchd daemon has
     no modern alternative: the data protection keychain (and the Secure
     Enclave) are unavailable outside a user context (Apple DTS, TN3137),
     so the file-based keychain APIs Apple marks deprecated are kept for
     the System keychain and confined to this file.

 Credits:
     Pulled from LAPS for macOS. Unlocking the System keychain was
     inspired by NoMAD Login; thanks to Joel Rennich, who also critiqued
     the keychain code when it needed rewriting for Xcode 11.1.
     Sources: stackoverflow.com/a/37539998/1694526; Apple's Keychain
     Services guide, Searching for Keychain Items; NoMADLogin-AD
     Mechs/KeychainAdd.swift (gitlab.com/orchardandgrove-oss).
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New keychain names under the 4.0 identity;
                        claude    password and creation date stored in one
                                  call; unreadable items fail closed; helpers
                                  for migration (attributes, deleting as root).

                                  New header and section style.
===============================================================================
*/

import Cocoa
import Security

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------------- //
// | Keychain item names | //
// ----------------------- //
// The service names of the stored and staged passwords.                     //
/// Keychain service names. 4.0 stores under the new identity; the legacy names are
/// read only by the migration helper (macOSLAPS-legacy) and removed in 5.0.
enum KeychainNames {
    static let current = "com.joshua-d-miller.macoslaps"
    static let pending = "com.joshua-d-miller.macoslaps.pending"
    static let legacyCurrent = "macOSLAPS"
    static let legacyPending = "macOSLAPS-pending"
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------- //
// | System keychain | //
// ------------------- //
// Saving, reading, exporting and deleting items. The deprecated calls stay  //
// in this file.                                                             //
/// Storage in the System keychain.
///
/// A root launchd daemon has no modern alternative: the data protection keychain
/// (and the Secure Enclave) are unavailable outside a user context (Apple DTS,
/// developer.apple.com/forums/thread/786171, TN3137). Targeting the System keychain
/// still needs the file-based keychain APIs, which Apple marks deprecated but keeps
/// supporting for daemons. The deprecated calls are confined to this file:
///   - `systemKeychain()` (SecKeychainOpen): the one way to address System.keychain
///   - `withoutUserInteraction` (SecKeychainSetUserInteractionAllowed): never prompt
///   - `exportPassword` (SecAccessCreate/SecTrustedApplication): legacy -getPassword
///     export only, removed in 5.0 together with -getPassword
/// Everything else uses the non-deprecated SecItem API.
class KeychainService {
    private static let systemKeychainPath = "/Library/Keychains/System.keychain"

    /// The System keychain. It is unlocked by the system (SystemKey), so no unlock call is needed.
    private class func systemKeychain() -> SecKeychain? {
        var keychain : SecKeychain?
        guard SecKeychainOpen(systemKeychainPath, &keychain) == errSecSuccess else { return nil }
        return keychain
    }

    /// Runs `body` with keychain UI disabled so a mismatched access list fails instead of prompting.
    private class func withoutUserInteraction<T>(_ body: () -> T) -> T {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }

    /// Stores `data` under `service`, with the comment "Created: <date>". `created` keeps
    /// an existing creation date (migration); by default it is now.
    class func savePassword(service: String, account: String, data: String, created: String? = nil) -> OSStatus {
        let dataFromString = data.data(using: String.Encoding.utf8, allowLossyConversion: false)
        let keychainRef : SecKeychain? = KeychainService.systemKeychain()
        
        guard let keychain = keychainRef, let passwordData = dataFromString else {
            return errSecParam
        }
        let creation_date = created ?? Constants.dateFormatter.string(from: Date())
        let comment_attribute : [ String : Any ] = [
            kSecAttrComment as String : "Created: \(creation_date)"
        ]
        let match : [ String : Any ] = [
            kSecClass as String       : kSecClassGenericPassword,
            kSecAttrService as String : service,
            kSecUseKeychain as String : keychain]

        // Update the existing item in place so a failure never leaves us with no item at all.
        var update = comment_attribute
        update[kSecValueData as String] = passwordData
        let update_status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if update_status != errSecItemNotFound {
            return update_status
        }

        // No item yet: create it with the creation date comment in one call, so a
        // failure can never leave a password stored without its date.
        var query : [String : Any] = [
            kSecClass as String        : kSecClassGenericPassword as String,
            kSecAttrService as String  : service,
            kSecAttrAccount as String  : account,
            kSecValueData as String    : passwordData,
            kSecUseKeychain as String  : keychain]
        query.merge(comment_attribute) { _, new in new }
        let add_status = SecItemAdd(query as CFDictionary, nil)
        if add_status == noErr || add_status == errSecDuplicateItem {
            return add_status
        }

        // Fallback for keychains that reject the comment on add (older code needed this):
        // add, then set the comment, and remove the item again if that second step fails.
        query.removeValue(forKey: kSecAttrComment as String)
        let plain_status = SecItemAdd(query as CFDictionary, nil)
        guard plain_status == noErr else {
            return plain_status
        }
        let comment_status = SecItemUpdate(match as CFDictionary, comment_attribute as CFDictionary)
        if comment_status != noErr {
            SecItemDelete(match as CFDictionary)
        }
        return comment_status
    }
    
    class func loadPassword(service: String) -> (String?, String?) {
        // Instantiate a new default keychain query
        // Tell the query to return a result
        guard let keychainRef = KeychainService.systemKeychain() else {
            laps_log.print("Unable to open the System keychain.", .error)
            exit(1)
        }
        let query : [String : Any] = [
            kSecClass as String            : kSecClassGenericPassword,
            kSecAttrService as String      : service,
            kSecReturnData as String       : kCFBooleanTrue!,
            kSecReturnAttributes as String : kCFBooleanTrue!,
            kSecMatchLimit as String       : kSecMatchLimitOne,
            kSecUseKeychain as String      : keychainRef]
        
        var item: AnyObject? = nil
        let status: OSStatus = withoutUserInteraction { SecItemCopyMatching(query as CFDictionary, &item) }
        if status == noErr {
            guard let existingItem = item as? [String: Any],
                  let passwordData = existingItem[String(kSecValueData)] as? Data,
                  let password = String(data: passwordData, encoding: String.Encoding.utf8) else {
                laps_log.print("The \(service) keychain item exists but its password could not be read. Refusing to continue so the stored password is not lost.", .error)
                exit(1)
            }
            guard let comment = existingItem[String(kSecAttrComment)] as? String,
                  comment.hasPrefix("Created: ") else {
                laps_log.print("There is currently no expiration date comment", .warn)
                return(password, nil)
            }
            let creationdate = String(comment.dropFirst("Created: ".count))
            
            return (password, creationdate)
        } else if status == errSecItemNotFound {
            // macOSLAPS Keychain Entry Not Found
            return(nil, "Not Found")
        }
        // Any other status means the item may exist but we cannot read it (for example
        // errSecInteractionNotAllowed when the item's access list does not trust this
        // binary). Never treat that as "no password stored": callers would fall back to
        // FirstPass and could lock the account out of its secureToken.
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        laps_log.print("Unable to read the \(service) keychain item (OSStatus \(status): \(message)). Refusing to continue so the stored password is not lost.", .error)
        exit(1)
    }
    class func exportPassword(service: String, account: String, data: String, expiration: String) -> OSStatus {
        let dataFromString = data.data(using: String.Encoding.utf8, allowLossyConversion: false)
        let keychainRef : SecKeychain? = KeychainService.systemKeychain()
        
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
            kSecUseKeychain as String  : keychainRef!]

        // Create new keychain entry
        SecItemAdd(query as CFDictionary, nil)
        
        // Add Creation Date as Comment
        // This seemed to require another query and update as it failed with the original
        let newquery : [ String : Any ] = [
            kSecClass as String       : kSecClassGenericPassword,
            kSecAttrService as String : service,
            kSecUseKeychain as String : keychainRef!]
        let comment_attribute : [ String : Any ] = [
            kSecAttrComment as String : "Created: \(expiration)"
        ]
        return SecItemUpdate(newquery as CFDictionary, comment_attribute as CFDictionary)
    }
    class func deleteExport(service: String) -> OSStatus {
        guard let keychain = KeychainService.systemKeychain() else { return errSecParam }
        let query : [String : Any] = [
            kSecClass as String            : kSecClassGenericPassword,
            kSecAttrService as String      : service,
            kSecUseKeychain as String      : keychain]
        let status = withoutUserInteraction { SecItemDelete(query as CFDictionary) }
        if status == noErr || status == errSecItemNotFound || getuid() != 0 {
            return status
        }
        // Items created by an earlier macOSLAPS (signed edu.psu.macOSLAPS, e.g. a 3.x/845
        // -getPassword export) don't let this identity delete them; root's security can.
        return deleteAsRoot(service: service) ? noErr : status
    }

    /// Deletes a System keychain item with /usr/bin/security (root only). The probe in
    /// step 20 showed this works for items whose access list doesn't trust this binary.
    class func deleteAsRoot(service: String) -> Bool {
        let result = Shell.execute(launchPath: "/usr/bin/security",
                                   arguments: ["delete-generic-password", "-s", service, systemKeychainPath], timeout: 30)
        return result.status == 0
    }

    /// Whether an item exists, and its comment, read with /usr/bin/security without the
    /// password (attributes need no access-list entry). nil when the keychain can't be read.
    class func itemAttributes(service: String) -> (exists: Bool, comment: String?)? {
        let result = Shell.execute(launchPath: "/usr/bin/security",
                                   arguments: ["find-generic-password", "-s", service, systemKeychainPath], timeout: 30)
        if result.status == 44 { return (false, nil) }   // errSecItemNotFound
        guard result.status == 0 else { return nil }
        var comment : String?
        for line in result.output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\"icmt\"<blob>=\""), text.hasSuffix("\"") {
                comment = String(text.dropFirst("\"icmt\"<blob>=\"".count).dropLast())
            }
        }
        return (true, comment)
    }
}

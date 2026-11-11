///
///  macOSLAPS-legacy
///  Migration helper inside macOSLAPS.app (Contents/Helpers).
///
///  Signed with the legacy identifier edu.psu.macOSLAPS (team 9UYK4F9BSM), which is the
///  only identity the keychain items created by macOSLAPS 3.x and 4.0.0 (845) trust.
///  macOSLAPS itself is signed com.joshua-d-miller.macoslaps and cannot read them.
///
///  It does two things and nothing else, and only for macOSLAPS:
///    read <service>        print {"password": ..., "comment": ...} as JSON on stdout
///    tombstone <service>   overwrite the item's password with MIGRATED (comment "Migrated")
///
///  It refuses to run unless it is root and its parent process is the signed macOSLAPS
///  app, so it can't be used as a general password dumper. Removed in 5.0.
///

import Foundation
import Security

let keychainPath = "/Library/Keychains/System.keychain"
let parentRequirement = """
    identifier "com.joshua-d-miller.macoslaps" and anchor apple generic \
    and certificate leaf[subject.OU] = "9UYK4F9BSM"
    """

func die(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

/// The parent process must be macOSLAPS, signed by team 9UYK4F9BSM.
func parentIsMacOSLAPS() -> Bool {
    #if MACOSLAPS_UNSIGNED_TEST
    // Unsigned CI test builds only: there is no Developer ID signature to check.
    return true
    #else
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: getppid()] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let parent = code else {
        return false
    }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(parentRequirement as CFString, [], &requirement) == errSecSuccess,
          let req = requirement else {
        return false
    }
    return SecCodeCheckValidity(parent, [], req) == errSecSuccess
    #endif
}

let args = CommandLine.arguments
guard args.count == 3, ["read", "tombstone"].contains(args[1]) else {
    die("macOSLAPS-legacy is used by macOSLAPS during migration and is not meant to be run directly.", 64)
}
guard getuid() == 0 else { die("Must be run as root.", 77) }
guard parentIsMacOSLAPS() else { die("Refusing: not started by macOSLAPS.", 77) }

let service = args[2]
var keychainRef: SecKeychain?
guard SecKeychainOpen(keychainPath, &keychainRef) == errSecSuccess, let keychain = keychainRef else {
    die("Unable to open the System keychain.", 2)
}
// Never show a keychain prompt: an access list that doesn't trust us must fail.
SecKeychainSetUserInteractionAllowed(false)

func describe(_ status: OSStatus) -> String {
    "OSStatus \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
}

switch args[1] {
case "read":
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseKeychain as String: keychain]
    var item: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { die("not found", 4) }
    guard status == errSecSuccess,
          let found = item as? [String: Any],
          let data = found[kSecValueData as String] as? Data,
          let password = String(data: data, encoding: .utf8) else {
        die("Unable to read \(service) (\(describe(status))).", 3)
    }
    let output: [String: String] = [
        "password": password,
        "comment": found[kSecAttrComment as String] as? String ?? ""]
    let json = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)

case "tombstone":
    let match: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecUseKeychain as String: keychain]
    let update: [String: Any] = [
        kSecValueData as String: "MIGRATED".data(using: .utf8)!,
        kSecAttrComment as String: "Migrated"]
    let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
    guard status == errSecSuccess else { die("Unable to retire \(service) (\(describe(status))).", 3) }

default:
    exit(64)
}

// Keychain identity probe (CI only). Mirrors how macOSLAPS stores its password in the
// System keychain, so the probe can show which code-signing identities can read an item.
//   kcprobe add <service> <password>   create the item (this binary becomes its trusted app)
//   kcprobe read <service>             print the password, or exit 3 with the OSStatus
//   kcprobe delete <service>           delete the item
import Foundation
import Security

func systemKeychain() -> SecKeychain {
    var kc: SecKeychain?
    guard SecKeychainOpen("/Library/Keychains/System.keychain", &kc) == errSecSuccess, let k = kc else {
        FileHandle.standardError.write("cannot open System keychain\n".data(using: .utf8)!); exit(2)
    }
    return k
}
func describe(_ s: OSStatus) -> String { "\(s) \(SecCopyErrorMessageString(s, nil) as String? ?? "")" }

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: kcprobe add|read|delete <service> [password]"); exit(64) }
let service = args[2]
let kc = systemKeychain()
SecKeychainSetUserInteractionAllowed(false)

switch args[1] {
case "add":
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: "probe", kSecValueData as String: args[3].data(using: .utf8)!,
                            kSecUseKeychain as String: kc]
    let s = SecItemAdd(q as CFDictionary, nil)
    if s != noErr { FileHandle.standardError.write("add failed: \(describe(s))\n".data(using: .utf8)!); exit(3) }
case "read":
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                            kSecUseKeychain as String: kc]
    var item: AnyObject?
    let s = SecItemCopyMatching(q as CFDictionary, &item)
    guard s == noErr, let d = item as? Data else {
        FileHandle.standardError.write("read failed: \(describe(s))\n".data(using: .utf8)!); exit(3)
    }
    print(String(decoding: d, as: UTF8.self))
case "delete":
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecUseKeychain as String: kc]
    let s = SecItemDelete(q as CFDictionary)
    if s != noErr { FileHandle.standardError.write("delete failed: \(describe(s))\n".data(using: .utf8)!); exit(3) }
default:
    exit(64)
}

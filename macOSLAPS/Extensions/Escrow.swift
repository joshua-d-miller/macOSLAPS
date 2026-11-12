/*
===============================================================================
 macOSLAPS | Extensions | Escrow.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-10
 Updated:   2026-11-11

 Purpose:
     -escrow prints the current password for an MDM inventory attribute
     (Jamf extension attribute, Intune custom attribute, Workspace ONE
     sensor, ...).
     Without EscrowCertificates: one line of JSON with the password in
     plain text; the MDM's own access controls protect it (the same
     exposure as 3.x and 845).
     With EscrowCertificates: the same JSON encrypted as CMS (PKCS #7
     EnvelopedData) to every listed certificate, printed as a PEM block.
     Only the holders of those certificates' private keys can read it.

 Decrypting:
     Windows: Unprotect-CmsMessage -Content (Get-Content escrow.txt -Raw)
     macOS:   security cms -D -i escrow.der (base64-decode the PEM body)
     Linux:   openssl cms -decrypt -inform PEM -in escrow.txt \
                  -recip cert.pem -inkey key.pem
     Certificates can be PEM strings, base64 DER strings or plist <data>.
     Use RSA certificates; Windows needs the Document Encryption EKU
     (1.3.6.1.4.1.311.80.1) for Unprotect-CmsMessage.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file: plaintext JSON or CMS escrow, fails
                        claude    closed when EscrowCertificates is set but
                                  unusable, reports a staged pending password;
                                  in device mode the reveal code instead of the
                                  password.

                                  New header and section style.
===============================================================================
*/

import Foundation
import Security
import CryptoKit
import CommonCrypto
import SystemConfiguration

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------- //
// | Escrow | //
// ---------- //
// Reads the certificates, builds the payload and prints it as JSON or CMS.  //
enum Escrow {
    struct Payload: Codable {
        let v: Int
        let account: String
        let password: String
        let set: String?
        let expires: String?
        let verified: Bool
        let host: String
        /// Staged rotation: the next password, not yet in use. Keep it with the current
        /// one; it becomes the account's password once macOSLAPS applies it.
        let pending: String?
        let pendingSet: String?
    }

    /// What `EscrowCertificates` holds.
    ///   - `configured`: the key has at least one entry, so encryption was asked for.
    ///     An absent key or an empty array means plaintext escrow.
    ///   - `certificates`: the entries that parsed as RSA certificates.
    ///   - `problems`: one line per entry that was skipped.
    struct CertificateConfig {
        let configured: Bool
        let certificates: [SecCertificate]
        let problems: [String]
        /// Encryption was asked for but nothing usable is configured: never fall back to plaintext.
        var unusable: Bool { configured && certificates.isEmpty }
    }

    static func certificateConfig() -> CertificateConfig {
        guard let raw = PreferenceStore.shared.rawValue(forKey: "EscrowCertificates") else {
            return CertificateConfig(configured: false, certificates: [], problems: [])
        }
        var entries : [Any] = (raw as? [Any]) ?? [raw]
        // Blank strings (an empty <string/> in a profile) don't count as configured.
        entries = entries.filter { !(($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false) }
        var certs : [SecCertificate] = []
        var problems : [String] = []
        for (index, entry) in entries.enumerated() {
            var der : Data?
            if let data = entry as? Data {
                der = data
            } else if let text = entry as? String {
                let body = text
                    .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                    .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                    .components(separatedBy: .whitespacesAndNewlines).joined()
                der = Data(base64Encoded: body)
            }
            guard let bytes = der, let cert = SecCertificateCreateWithData(nil, bytes as CFData) else {
                problems.append("entry \(index + 1) is not a valid certificate (PEM, base64 DER or <data>)")
                continue
            }
            guard let key = SecCertificateCopyKey(cert),
                  let attributes = SecKeyCopyAttributes(key) as? [String: Any],
                  (attributes[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeRSA as String) else {
                problems.append("entry \(index + 1) is not an RSA certificate")
                continue
            }
            certs.append(cert)
        }
        return CertificateConfig(configured: !entries.isEmpty, certificates: certs, problems: problems)
    }

    /// Usable certificates in `EscrowCertificates` (logs a warning for each skipped entry).
    static func certificates() -> [SecCertificate] {
        let config = certificateConfig()
        for problem in config.problems {
            laps_log.print("EscrowCertificates \(problem); it was skipped.", .warn)
        }
        return config.certificates
    }

    /// SHA-256 fingerprint of a certificate (hex, uppercase), for -status and logs.
    static func fingerprint(_ cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        return sha256Hex(der)
    }

    /// CMS EnvelopedData (RFC 5652) of `content` for all `recipients`, DER encoded.
    ///
    /// Built directly instead of with CMSEncoder, which only offers 3DES. Uses
    /// AES-256-CBC for the content and RSA (PKCS #1 v1.5) key transport, one
    /// KeyTransRecipientInfo per certificate identified by issuer and serial number.
    /// That combination is what Protect-CmsMessage and openssl produce by default, so
    /// Unprotect-CmsMessage, openssl cms and security cms all read it.
    static func envelope(_ content: Data, recipients: [SecCertificate]) throws -> Data {
        var key = Data(count: 32), iv = Data(count: 16)
        guard key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
              iv.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else {
            throw EscrowError.crypto("random key generation failed")
        }
        defer { key.resetBytes(in: 0..<key.count) }
        let ciphertext = try aes256CBC(content, key: key, iv: iv)

        var recipientInfos : [Data] = []
        for cert in recipients {
            guard let publicKey = SecCertificateCopyKey(cert),
                  let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
                  (attributes[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeRSA as String) else {
                throw EscrowError.crypto("EscrowCertificates must contain RSA certificates")
            }
            var error : Unmanaged<CFError>?
            guard let wrapped = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, key as CFData, &error) as Data? else {
                throw EscrowError.crypto("RSA key wrap failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            }
            let (issuer, serial) = try DER.issuerAndSerial(of: SecCertificateCopyData(cert) as Data)
            recipientInfos.append(DER.sequence([
                DER.integer(0),
                DER.sequence([issuer, serial]),
                DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null]),
                DER.octetString(wrapped)]))
        }
        let encryptedContentInfo = DER.sequence([
            DER.oid("1.2.840.113549.1.7.1"),
            DER.sequence([DER.oid("2.16.840.1.101.3.4.1.42"), DER.octetString(iv)]),
            DER.tagged(0x80, ciphertext)])
        let envelopedData = DER.sequence([DER.integer(0), DER.set(recipientInfos), encryptedContentInfo])
        return DER.sequence([DER.oid("1.2.840.113549.1.7.3"), DER.tagged(0xA0, envelopedData)])
    }

    private static func aes256CBC(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var written = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            plaintext.withUnsafeBytes { p in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                p.baseAddress, plaintext.count, o.baseAddress, outCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw EscrowError.crypto("AES encryption failed (\(status))") }
        return out.prefix(written)
    }

    static func pem(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----"
    }

    enum EscrowError: Error, CustomStringConvertible {
        case crypto(String)
        case der(String)
        var description: String {
            switch self {
            case .crypto(let message): return message
            case .der(let message): return "Certificate parse error: \(message)"
            }
        }
    }

    /// Device mode: the reveal code instead of the password. The password never leaves the Mac.
    struct DevicePayload: Codable {
        let v: Int
        let mode: String
        let account: String
        let revealCode: String
        let codeSet: String?
        let expires: String?
        let rotatesAt: String?
        let verified: Bool
        let host: String
    }

    /// `-escrow`: print the payload (plain JSON or CMS PEM) and exit.
    static func run() -> Never {
        let (password, created) = KeychainService.loadPassword(service: KeychainNames.current)
        guard let current = password else {
            print("{\"v\":1,\"status\":\"no-password\",\"account\":\(jsonString(Constants.local_admin))}")
            exit(0)
        }
        let record = LocalTools.connect()
        let verified = RunState.storedPasswordWorks(current, created: created, record: record)
        if !verified {
            laps_log.print("The stored password does not currently work for \(Constants.local_admin). Escrowing it anyway and reporting verified=false.", .warn)
        }
        let createdDate = (created == nil || created == "Not Found") ? nil : created
        let expires = LocalTools.get_expiration_date().map { Constants.dateFormatter.string(from: $0) }
        let staged = Reveal.deviceMode ? nil : Staging.pending()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded : Data?
        if Reveal.deviceMode {
            guard let code = Reveal.currentCode() else {
                printEscrowError("no reveal code could be created")
                exit(1)
            }
            encoded = try? encoder.encode(DevicePayload(v: 1, mode: "device", account: Constants.local_admin,
                revealCode: code, codeSet: RunState.value("revealCodeSet"), expires: isoDate(expires),
                rotatesAt: RunState.value("rotatesAt"), verified: verified, host: computerName()))
        } else {
            encoded = try? encoder.encode(Payload(v: 1, account: Constants.local_admin, password: current, set: isoDate(createdDate),
                expires: isoDate(expires), verified: verified, host: computerName(),
                pending: staged?.password, pendingSet: isoDate(staged?.created)))
        }
        guard let json = encoded else {
            laps_log.print("Unable to encode the escrow payload.", .error)
            exit(1)
        }
        let config = certificateConfig()
        for problem in config.problems {
            laps_log.print("EscrowCertificates \(problem); it was skipped.", .warn)
        }
        if config.unusable {
            // Encryption was configured, so never print the password in plain text. Print a
            // non-secret error instead of nothing, so the MDM attribute shows the problem
            // rather than an empty value (which some MDMs store over the last good escrow).
            laps_log.print("EscrowCertificates is set but has no usable RSA certificate. The password was NOT printed.", .error)
            printEscrowError("EscrowCertificates is set but has no usable RSA certificate")
            exit(1)
        }
        if !config.configured {
            print(String(data: json, encoding: .utf8)!)
            if staged != nil { Staging.noteExported() } else { Staging.noteEscrowRan() }
            exit(0)
        }
        do {
            let der = try envelope(json, recipients: config.certificates)
            print(pem(der, label: "CMS"))
            if staged != nil { Staging.noteExported() } else { Staging.noteEscrowRan() }
            exit(0)
        } catch {
            laps_log.print("Unable to encrypt the escrow payload: \(error). The password was NOT printed.", .error)
            printEscrowError("encryption failed: \(error)")
            exit(1)
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------- //
// | Helpers | //
// ----------- //
// Computer name, JSON strings and hashes used by the payload.               //
/// The Mac's computer name. (ProcessInfo.hostName does a DNS lookup and can stall for seconds.)
func computerName() -> String {
    return (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "unknown"
}

/// One line of non-secret JSON describing why escrow output was withheld.
func printEscrowError(_ message: String) {
    print("{\"v\":1,\"status\":\"error\",\"error\":\(jsonString(message))}")
}

/// JSON-escaped string literal.
func jsonString(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
    let array = String(data: data, encoding: .utf8)!
    return String(array.dropFirst().dropLast())
}

/// SHA-256 as uppercase hex.
func sha256Hex(_ data: Data) -> String {
    return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------- //
// | DER encoding | //
// ---------------- //
// Just enough DER to build the CMS EnvelopedData and read a certificate's   //
// issuer and serial number.                                                 //
/// Minimal DER encoder/decoder for the CMS structure above.
enum DER {
    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes : [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func tlv(_ tag: UInt8, _ value: Data) -> Data { Data([tag]) + length(value.count) + value }
    static func tagged(_ tag: UInt8, _ value: Data) -> Data { tlv(tag, value) }
    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    /// SET OF, sorted by encoding as DER requires.
    static func set(_ items: [Data]) -> Data {
        tlv(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +))
    }
    static func octetString(_ value: Data) -> Data { tlv(0x04, value) }
    static let null = Data([0x05, 0x00])
    static func integer(_ value: Int) -> Data {
        var bytes : [UInt8] = []
        var v = value
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }
    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").map { UInt64($0)! }
        var body : [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for var arc in parts.dropFirst(2) {
            var chunk : [UInt8] = [UInt8(arc & 0x7F)]
            arc >>= 7
            while arc > 0 { chunk.insert(UInt8(arc & 0x7F) | 0x80, at: 0); arc >>= 7 }
            body += chunk
        }
        return tlv(0x06, Data(body))
    }

    /// Reads one TLV at `offset`; returns (tag, full element, value range).
    static func read(_ data: Data, at offset: Int) throws -> (tag: UInt8, element: Range<Int>, value: Range<Int>) {
        let bytes = [UInt8](data)
        guard offset + 2 <= bytes.count else { throw Escrow.EscrowError.der("truncated") }
        let tag = bytes[offset]
        var len = Int(bytes[offset + 1]), header = 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, offset + 2 + n <= bytes.count else { throw Escrow.EscrowError.der("bad length") }
            len = 0
            for i in 0..<n { len = (len << 8) | Int(bytes[offset + 2 + i]) }
            header += n
        }
        let start = offset + header
        guard start + len <= bytes.count else { throw Escrow.EscrowError.der("length past end") }
        return (tag, offset..<(start + len), start..<(start + len))
    }

    /// The exact DER of the certificate's issuer Name and serialNumber INTEGER.
    static func issuerAndSerial(of cert: Data) throws -> (Data, Data) {
        let d = Data(cert)  // re-base indices at 0
        let certificate = try read(d, at: 0)
        let tbs = try read(d, at: certificate.value.lowerBound)
        var cursor = tbs.value.lowerBound
        var element = try read(d, at: cursor)
        if element.tag == 0xA0 {               // [0] version
            cursor = element.element.upperBound
            element = try read(d, at: cursor)
        }
        guard element.tag == 0x02 else { throw Escrow.EscrowError.der("serial number not found") }
        let serial = d.subdata(in: element.element)
        cursor = element.element.upperBound
        let signature = try read(d, at: cursor)    // AlgorithmIdentifier
        cursor = signature.element.upperBound
        let issuer = try read(d, at: cursor)
        guard issuer.tag == 0x30 else { throw Escrow.EscrowError.der("issuer not found") }
        return (d.subdata(in: issuer.element), serial)
    }
}

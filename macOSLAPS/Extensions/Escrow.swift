///
///  Escrow.swift
///  macOSLAPS
///
///  Created November 10, 2026
///
///  `-escrow` prints the current password for an MDM inventory attribute
///  (Jamf extension attribute, Intune custom attribute, WS1 sensor, ...).
///
///  - Without `EscrowCertificates`: one line of JSON with the password in plain
///    text. The MDM's own access controls protect it (same exposure as 3.x/4.0b845).
///  - With `EscrowCertificates`: the same JSON, encrypted as CMS (PKCS #7
///    EnvelopedData) to every listed certificate, printed as a PEM block. Only the
///    holders of those certificates' private keys can read it:
///      Windows:  Unprotect-CmsMessage -Content (Get-Content escrow.txt -Raw)
///      macOS:    security cms -D -i escrow.der   (base64-decode the PEM body first)
///      Linux:    openssl cms -decrypt -inform PEM -in escrow.txt -recip cert.pem -inkey key.pem
///
///  Certificates can be given as PEM strings, base64 DER strings or plist <data>.
///  Use RSA certificates (Windows needs the Document Encryption EKU,
///  1.3.6.1.4.1.311.80.1, for Unprotect-CmsMessage).

import Foundation
import Security
import CryptoKit

enum Escrow {
    struct Payload: Codable {
        let v: Int
        let account: String
        let password: String
        let set: String?
        let expires: String?
        let verified: Bool
        let host: String
    }

    /// Certificates configured in `EscrowCertificates`, or an empty array.
    static func certificates() -> [SecCertificate] {
        guard let raw = PreferenceStore.shared.rawValue(forKey: "EscrowCertificates") else { return [] }
        let entries : [Any] = (raw as? [Any]) ?? [raw]
        var certs : [SecCertificate] = []
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
                laps_log.print("EscrowCertificates entry \(index + 1) is not a valid certificate and was skipped.", .warn)
                continue
            }
            certs.append(cert)
        }
        return certs
    }

    /// SHA-256 fingerprint of a certificate (hex, uppercase), for -status and logs.
    static func fingerprint(_ cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        return sha256Hex(der)
    }

    /// CMS EnvelopedData of `content` for all `recipients`, DER encoded.
    static func envelope(_ content: Data, recipients: [SecCertificate]) throws -> Data {
        var encoder : CMSEncoder?
        var status = CMSEncoderCreate(&encoder)
        guard status == errSecSuccess, let enc = encoder else { throw EscrowError.cms("create", status) }
        status = CMSEncoderAddRecipients(enc, recipients as CFArray)
        guard status == errSecSuccess else { throw EscrowError.cms("add recipients", status) }
        status = content.withUnsafeBytes { buffer in
            CMSEncoderUpdateContent(enc, buffer.baseAddress!, content.count)
        }
        guard status == errSecSuccess else { throw EscrowError.cms("update content", status) }
        var encoded : CFData?
        status = CMSEncoderCopyEncodedContent(enc, &encoded)
        guard status == errSecSuccess, let out = encoded else { throw EscrowError.cms("encode", status) }
        return out as Data
    }

    static func pem(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----"
    }

    enum EscrowError: Error, CustomStringConvertible {
        case cms(String, OSStatus)
        var description: String {
            switch self {
            case .cms(let step, let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
                return "CMS \(step) failed (OSStatus \(status): \(message))"
            }
        }
    }

    /// `-escrow`: print the payload (plain JSON or CMS PEM) and exit.
    static func run() -> Never {
        let (password, created) = KeychainService.loadPassword(service: "macOSLAPS")
        guard let current = password else {
            print("{\"v\":1,\"status\":\"no-password\",\"account\":\(jsonString(Constants.local_admin))}")
            exit(0)
        }
        let record = LocalTools.connect()
        let verified = (try? record.verifyPassword(current)) != nil
        if !verified {
            laps_log.print("The stored password does not currently work for \(Constants.local_admin). Escrowing it anyway and reporting verified=false.", .warn)
        }
        let createdDate = (created == nil || created == "Not Found") ? nil : created
        let expires = LocalTools.get_expiration_date().map { Constants.dateFormatter.string(from: $0) }
        let payload = Payload(v: 1, account: Constants.local_admin, password: current, set: createdDate,
                              expires: expires, verified: verified, host: ProcessInfo.processInfo.hostName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let json = try? encoder.encode(payload) else {
            laps_log.print("Unable to encode the escrow payload.", .error)
            exit(1)
        }
        let certs = certificates()
        if certs.isEmpty {
            print(String(data: json, encoding: .utf8)!)
            exit(0)
        }
        do {
            let der = try envelope(json, recipients: certs)
            print(pem(der, label: "CMS"))
            exit(0)
        } catch {
            laps_log.print("Unable to encrypt the escrow payload: \(error). Nothing was printed.", .error)
            exit(1)
        }
    }
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

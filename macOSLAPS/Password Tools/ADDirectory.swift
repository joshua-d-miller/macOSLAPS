/*
===============================================================================
 macOSLAPS | Password Tools | ADDirectory.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-17
 Updated:   2026-11-17

 Purpose:
     Where macOSLAPS reads and writes the computer's LAPS attributes in
     Active Directory. Normally through Open Directory, on the domain
     controller the Mac's binding uses (as in every earlier release). Over
     LDAP to a domain controller macOSLAPS chooses when:
       - PreferredDC is set: always that DC, or
       - the bound DC can't be written (a read-only DC): the first
         writable DC found in DNS.
     LDAP runs as the computer account: its password is in the System
     keychain under the binding's node name, kinit gets a ticket into a
     private cache, and ldapsearch / ldapmodify use it (GSSAPI, signed and
     sealed). Values go through stdin, never the command line.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-17   joshua    New file. PreferredDC works (it never did:
                        claude    the setting went to an unused
                                  configuration), and a read-only bound DC
                                  falls back to a writable one.
===============================================================================
*/

import Foundation
import OpenDirectory

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------- //
// | The interface | //
// ----------------- //
// Attribute names are AD's own (ms-Mcs-AdmPwd), without OD's prefix.        //
protocol ADBackend {
    /// For the log: how and where macOSLAPS reaches AD.
    var description: String { get }
    /// The attribute's first value, or nil when it has none (or can't be read).
    func value(_ attribute: String) -> Any?
    /// Replaces the attribute's value.
    func write(_ attribute: String, _ value: String) throws
}

/// The computer's object in AD, and the way to it. A class, so a fallback to another
/// domain controller during a run is seen by everything holding it.
final class ADComputer {
    private(set) var backend : ADBackend
    let binding : ADBinding
    init(backend: ADBackend, binding: ADBinding) {
        self.backend = backend
        self.binding = binding
    }
    func value(_ attribute: String) -> Any? { backend.value(attribute) }
    func write(_ attribute: String, _ value: String) throws { try backend.write(attribute, value) }
    func use(_ other: ADBackend) { backend = other }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------- //
// | Binding | //
// ----------- //
// What the AD plugin knows about this Mac's binding.                        //
struct ADBinding {
    /// "/Active Directory/<SHORT>", also the keychain item holding the computer password.
    let nodeName : String
    let domain : String
    /// The computer account, "<NAME>$".
    let trustAccount : String

    var realm : String { domain.uppercased() }
    /// DC=example,DC=com
    var baseDN : String { domain.split(separator: ".").map { "DC=\($0)" }.joined(separator: ",") }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------ //
// | Open Directory | //
// ------------------ //
// The computer record through the AD plugin (the bound DC).                 //
struct ODBackend: ADBackend {
    let record : ODRecord
    var description : String { "Open Directory (the domain controller this Mac's binding uses)" }
    func value(_ attribute: String) -> Any? {
        (try? record.values(forAttribute: "dsAttrTypeNative:\(attribute)"))?.first
    }
    func write(_ attribute: String, _ value: String) throws {
        try record.setValue(value, forAttribute: "dsAttrTypeNative:\(attribute)")
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------- //
// | LDAP | //
// -------- //
// To one domain controller, as the computer account.                        //
final class LDAPBackend: ADBackend {
    enum Failure: Error, CustomStringConvertible {
        case step(String)
        var description: String {
            switch self { case .step(let text): return text }
        }
    }

    let server : String
    let dn : String
    private let cache : String
    var description : String { "LDAP to \(server)" }

    /// Folder for the private Kerberos ticket caches (root only); emptied at exit.
    static let cacheFolder = "/var/run/macoslaps"
    private static var caches : [String] = []
    private static var cleanupRegistered = false

    private init(server: String, dn: String, cache: String) {
        self.server = server
        self.dn = dn
        self.cache = cache
    }

    /// Signs in to `server` as the computer and finds the computer's object there.
    static func open(server: String, binding: ADBinding) throws -> LDAPBackend {
        // 1. The computer's password, kept by the AD plugin in the System keychain.
        let secret = Shell.execute(launchPath: "/usr/bin/security",
                                   arguments: ["find-generic-password", "-s", binding.nodeName, "-w",
                                               "/Library/Keychains/System.keychain"],
                                   timeout: 30, separateErrors: true)
        guard secret.status == 0, !secret.output.isEmpty else {
            throw Failure.step("the computer account's password (keychain item \(binding.nodeName)) could not be read (security exit \(secret.status))")
        }
        // 2. A ticket as the computer, in a private cache.
        try? FileManager.default.createDirectory(atPath: cacheFolder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let cache = "FILE:\(cacheFolder)/krb5cc_\(getpid())_\(caches.count)"
        registerCleanup(cache)
        let principal = "\(binding.trustAccount)@\(binding.realm)"
        let kinit = Shell.execute(launchPath: "/usr/bin/kinit",
                                  arguments: ["--password-file=STDIN", "-c", cache, principal],
                                  timeout: 30, separateErrors: true,
                                  input: Data((secret.output + "\n").utf8))
        guard kinit.status == 0 else {
            throw Failure.step("kinit as \(principal) failed (\(kinit.errors.isEmpty ? "exit \(kinit.status)" : kinit.errors))")
        }
        // 3. The computer's object on that DC.
        let filter = "(sAMAccountName=\(ldapEscape(binding.trustAccount)))"
        let search = run("/usr/bin/ldapsearch", ["-LLL", "-Q", "-Y", "GSSAPI", "-H", "ldap://\(server)",
                                                 "-b", binding.baseDN, filter, "dn"], cache: cache)
        guard search.status == 0, let found = LDIF.values(of: "dn", in: search.output).first else {
            throw Failure.step("\(binding.trustAccount) was not found on \(server) (ldapsearch exit \(search.status)\(search.errors.isEmpty ? "" : ": \(search.errors)"))")
        }
        return LDAPBackend(server: server, dn: found, cache: cache)
    }

    func value(_ attribute: String) -> Any? {
        let result = LDAPBackend.run("/usr/bin/ldapsearch",
                                     ["-LLL", "-Q", "-Y", "GSSAPI", "-H", "ldap://\(server)", "-b", dn, "-s", "base",
                                      "(objectClass=*)", attribute], cache: cache)
        guard result.status == 0 else { return nil }
        return LDIF.values(of: attribute, in: result.output).first
    }

    func write(_ attribute: String, _ value: String) throws {
        let change = LDIF.replace(dn: dn, attribute: attribute, value: value)
        let result = LDAPBackend.run("/usr/bin/ldapmodify", ["-Q", "-Y", "GSSAPI", "-H", "ldap://\(server)"],
                                     cache: cache, input: Data(change.utf8))
        guard result.status == 0 else {
            // e.g. 10 (referral: a read-only DC), 50 (insufficient access).
            throw Failure.step("ldapmodify \(attribute) on \(server) exited \(result.status)\(result.errors.isEmpty ? "" : ": \(result.errors)")")
        }
    }

    private static func run(_ tool: String, _ arguments: [String], cache: String, input: Data? = nil) -> Shell.Result {
        Shell.execute(launchPath: tool, arguments: arguments, timeout: 60, separateErrors: true,
                      input: input, environment: ["KRB5CCNAME": cache])
    }

    /// Ticket caches are removed when macOSLAPS exits, however it exits.
    private static func registerCleanup(_ cache: String) {
        caches.append(cache)
        guard !cleanupRegistered else { return }
        cleanupRegistered = true
        atexit {
            for cache in LDAPBackend.caches {
                unlink(String(cache.dropFirst("FILE:".count)))
            }
        }
    }

    /// RFC 4515: escapes the characters that mean something in a search filter.
    static func ldapEscape(_ text: String) -> String {
        var out : [UInt8] = []
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "*"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"), 0:
                out += Array(String(format: "\\%02x", byte).utf8)
            default:
                out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------- //
// | LDIF | //
// -------- //
// Reading ldapsearch output and writing a change.                           //
enum LDIF {
    /// The values of `attribute` in ldapsearch -LLL output: folded lines joined,
    /// base64 values ("attr:: ...") decoded.
    static func values(of attribute: String, in text: String) -> [String] {
        var lines : [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(" "), !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            else { lines.append(line) }
        }
        let name = attribute.lowercased()
        return lines.compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name else { return nil }
            let rest = line[line.index(after: colon)...]
            if rest.hasPrefix(":") {
                let encoded = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                return Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) }
            }
            return rest.trimmingCharacters(in: .whitespaces)
        }
    }

    /// A modify that replaces one attribute. The DN and value are base64 encoded, so
    /// no character in them can change the LDIF.
    static func replace(dn: String, attribute: String, value: String) -> String {
        """
        dn:: \(Data(dn.utf8).base64EncodedString())
        changetype: modify
        replace: \(attribute)
        \(attribute):: \(Data(value.utf8).base64EncodedString())
        -

        """
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------ //
// | Writable DCs in DNS | //
// ------------------------ //
// For a read-only bound DC: _ldap._tcp.dc._msdcs.<domain>, by priority.     //
enum DomainControllers {
    static func fromDNS(domain: String) -> [String] {
        let result = Shell.execute(launchPath: "/usr/bin/dig",
                                   arguments: ["+short", "_ldap._tcp.dc._msdcs.\(domain)", "SRV"], timeout: 30)
        guard result.status == 0 else { return [] }
        return parseSRV(result.output)
    }

    /// "priority weight port target." lines → targets, lowest priority first.
    static func parseSRV(_ text: String) -> [String] {
        let records = text.split(separator: "\n").compactMap { line -> (Int, Int, String)? in
            let parts = line.split(separator: " ")
            guard parts.count == 4, let priority = Int(parts[0]), let weight = Int(parts[1]) else { return nil }
            var target = String(parts[3])
            if target.hasSuffix(".") { target.removeLast() }
            return target.isEmpty ? nil : (priority, weight, target)
        }
        var seen = Set<String>()
        return records.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .map { $0.2 }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

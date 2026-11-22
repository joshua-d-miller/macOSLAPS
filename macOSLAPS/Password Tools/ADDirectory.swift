/*
===============================================================================
 macOSLAPS | Password Tools | ADDirectory.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-17
 Updated:   2026-11-22

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
 4.0.0     2026-11-22   joshua    The writability check and the fallback to
                        claude    a writable DC are in Writability.ensure,
                                  away from logging and exit, so unit tests
                                  drive them with fake backends. The check
                                  makes a real change (time + 1, then back):
                                  a Samba RODC accepted the same value.
 4.0.0     2026-11-17   joshua    New file. PreferredDC works (it never did:
                        claude    the setting went to an unused
                                  configuration), and a read-only bound DC
                                  falls back to a writable one.
===============================================================================
*/

import Foundation
import OpenDirectory
import dnssd

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
    /// True when it reaches whichever DC the binding picks, so another DC may
    /// be tried if that one refuses. False for a DC macOSLAPS chose itself.
    var followsBinding: Bool { get }
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
// --------------- //
// | Writability | //
// --------------- //
// Before the local password changes: rewrite the current expiration         //
// time(s) to prove the DC takes writes. A DC that follows the binding and   //
// refuses (a read-only DC) is replaced by the first candidate that takes    //
// the rewrite. No logging and no exit here; ADTools does both.              //
enum Writability {
    /// A domain controller that was tried and didn't work, and why.
    struct Attempt: Equatable {
        let server : String
        let reason : String
    }
    enum Outcome: Equatable {
        /// The current backend took the rewrite.
        case writable
        /// It refused and may not be replaced (a DC macOSLAPS chose).
        case refused(reason: String)
        /// It refused; `server` took the rewrite and the computer now uses it.
        case switched(server: String, refusal: String, skipped: [Attempt])
        /// It refused, and no candidate took the rewrite.
        case noWritableDC(refusal: String, skipped: [Attempt])
    }

    /// Proves each attribute can be written with a real change: a time is
    /// moved 100 ns later and put back; a missing or unreadable one gets
    /// `placeholder`. Writing the same value isn't proof: a read-only DC
    /// (Samba) accepts a modify that changes nothing.
    static func rewrite(_ target: ADBackend, _ attributes: [String],
                        placeholder: String) throws {
        for attribute in attributes {
            if let current = target.value(attribute) as? String, let time = Int64(current) {
                try target.write(attribute, String(time &+ 1))
                try target.write(attribute, current)
            } else {
                try target.write(attribute, placeholder)
            }
        }
    }

    /// `candidates` (asked only after a refusal): DCs in the order to try.
    /// `open` reaches one of them.
    static func ensure(_ computer: ADComputer, attributes: [String], placeholder: String,
                       candidates: () -> [String], open: (String) throws -> ADBackend,
                       explain: (Error) -> String) -> Outcome {
        let refusal : String
        do {
            try rewrite(computer.backend, attributes, placeholder: placeholder)
            return .writable
        } catch {
            refusal = explain(error)
        }
        guard computer.backend.followsBinding else { return .refused(reason: refusal) }
        var skipped : [Attempt] = []
        for server in candidates() {
            do {
                let other = try open(server)
                try rewrite(other, attributes, placeholder: placeholder)
                computer.use(other)
                return .switched(server: server, refusal: refusal, skipped: skipped)
            } catch {
                skipped.append(Attempt(server: server, reason: explain(error)))
            }
        }
        return .noWritableDC(refusal: refusal, skipped: skipped)
    }
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
    var followsBinding : Bool { true }
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
    var followsBinding : Bool { false }

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
// ----------------------- //
// | Writable DCs in DNS | //
// ----------------------- //
// For a read-only bound DC: _ldap._tcp.dc._msdcs.<domain>, through the      //
// system resolver (dig and host ignore /etc/resolver, which split-DNS       //
// setups and VPN clients use).                                              //
enum DomainControllers {
    typealias SRV = (priority: Int, weight: Int, target: String)

    static func fromDNS(domain: String) -> [String] {
        order(query("_ldap._tcp.dc._msdcs.\(domain)"))
    }

    /// Lowest priority first, then highest weight; duplicates dropped.
    static func order(_ records: [SRV]) -> [String] {
        var seen = Set<String>()
        return records.sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.weight > $1.weight }
            .map { $0.target.hasSuffix(".") ? String($0.target.dropLast()) : $0.target }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The SRV records for `name`, answered by mDNSResponder (the system resolver).
    static func query(_ name: String, timeout: TimeInterval = 5) -> [SRV] {
        let answers = SRVAnswers()
        var reference : DNSServiceRef?
        let error = DNSServiceQueryRecord(&reference, 0, 0, name, UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN),
            { _, flags, _, errorCode, _, _, _, length, data, _, context in
                guard let context = context else { return }
                let answers = Unmanaged<SRVAnswers>.fromOpaque(context).takeUnretainedValue()
                if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { answers.done = true }
                guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let data = data,
                      let record = DomainControllers.parse(UnsafeRawBufferPointer(start: data, count: Int(length))) else { return }
                answers.records.append(record)
            }, Unmanaged.passUnretained(answers).toOpaque())
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let service = reference else { return [] }
        defer { DNSServiceRefDeallocate(service) }
        let deadline = Date().addingTimeInterval(timeout)
        while !answers.done {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            var descriptor = pollfd(fd: DNSServiceRefSockFD(service), events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(left * 1000)) > 0,
                  DNSServiceProcessResult(service) == DNSServiceErrorType(kDNSServiceErr_NoError) else { break }
        }
        return answers.records
    }

    /// SRV RDATA: priority, weight, port (two bytes each), then the target as labels.
    static func parse(_ bytes: UnsafeRawBufferPointer) -> SRV? {
        guard bytes.count > 7 else { return nil }
        let priority = Int(bytes[0]) << 8 | Int(bytes[1])
        let weight = Int(bytes[2]) << 8 | Int(bytes[3])
        var labels : [String] = []
        var index = 6
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { break }
            index += 1
            guard index + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[index..<index + length], as: UTF8.self))
            index += length
        }
        return labels.isEmpty ? nil : (priority, weight, labels.joined(separator: "."))
    }
}

/// What the DNS callback collects (a class, so the C callback can reach it).
final class SRVAnswers {
    var records : [DomainControllers.SRV] = []
    var done = false
}

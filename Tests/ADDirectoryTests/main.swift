/*
===============================================================================
 macOSLAPS | Tests | ADDirectoryTests/main.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-17
 Updated:   2026-11-22

 Purpose:
     Unit tests for the LDAP helpers in
     macOSLAPS/Password Tools/ADDirectory.swift: reading ldapsearch
     output, writing a change, escaping a search filter, and reading and
     ordering the domain controllers DNS returns, and the writability
     check with its fallback to a writable DC (fake backends). No domain,
     Xcode project or root needed.

 Usage:
     swiftc macOSLAPS/Extensions/Shell.swift \
         "macOSLAPS/Password Tools/ADDirectory.swift" \
         Tests/ADDirectoryTests/main.swift -o ad-tests
     ./ad-tests
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-22   joshua    Writability.ensure with fake backends: a
                        claude    refusing bound DC falls back to the first
                                  candidate that takes the write; a chosen
                                  DC never does; an RODC that accepts a
                                  no-change write is still caught; a DC
                                  picked from DNS isn't tried twice.
 4.0.0     2026-11-17   joshua    New file.
                        claude
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------- //
// | Checks | //
// ---------- //
var checks = 0, failures = 0
func expect(_ ok: Bool, _ message: String) {
    checks += 1
    if ok { print("PASS: \(message)") } else { failures += 1; print("FAIL: \(message)") }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------------- //
// | Reading ldapsearch | //
// ---------------------- //
let folded = """
dn: CN=CIMAC42,CN=Computers,DC=laps,DC=t
 est

"""
expect(LDIF.values(of: "dn", in: folded) == ["CN=CIMAC42,CN=Computers,DC=laps,DC=test"], "a folded DN is joined")
let encoded = "ms-Mcs-AdmPwd:: \(Data("pä:ss\\word".utf8).base64EncodedString())\n"
expect(LDIF.values(of: "ms-mcs-admpwd", in: encoded) == ["pä:ss\\word"], "a base64 value is decoded, the name matched in any case")
let plain = "dn: CN=X,DC=t\nms-Mcs-AdmPwdExpirationTime: 134000000000000000\n"
expect(LDIF.values(of: "ms-Mcs-AdmPwdExpirationTime", in: plain) == ["134000000000000000"], "a plain value")
expect(LDIF.values(of: "msLAPS-Password", in: plain).isEmpty, "a missing attribute has no values")
expect(LDIF.values(of: "dn", in: "dn:: \(Data("CN=Café,DC=t".utf8).base64EncodedString())\n") == ["CN=Café,DC=t"], "a base64 DN")

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------- //
// | Writing a change | //
// ------------------- //
let change = LDIF.replace(dn: "CN=X,DC=t", attribute: "ms-Mcs-AdmPwd", value: "a\nb: c")
let lines = change.components(separatedBy: "\n")
expect(lines.count == 6 && lines[1] == "changetype: modify" && lines[2] == "replace: ms-Mcs-AdmPwd" && lines[4] == "-",
       "a modify that replaces one attribute")
expect(lines[3] == "ms-Mcs-AdmPwd:: \(Data("a\nb: c".utf8).base64EncodedString())", "the value is base64, so a newline can't add lines")
expect(lines[0] == "dn:: \(Data("CN=X,DC=t".utf8).base64EncodedString())", "the DN is base64")

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------------- //
// | Filter escaping | //
// -------------------- //
expect(LDAPBackend.ldapEscape("CIMAC42$") == "CIMAC42$", "a normal account name is unchanged")
expect(LDAPBackend.ldapEscape("a*b(c)d\\e") == "a\\2ab\\28c\\29d\\5ce", "filter characters are escaped")
expect(LDAPBackend.ldapEscape("Café$") == "Café$", "non-ASCII stays intact")

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------ //
// | DNS SRV order | //
// ------------------ //
let records : [DomainControllers.SRV] = [(10, 100, "dc2.laps.test."), (0, 50, "dc1.laps.test."),
                                         (0, 100, "dc3.laps.test."), (0, 100, "DC3.laps.test.")]
expect(DomainControllers.order(records) == ["dc3.laps.test", "dc1.laps.test", "dc2.laps.test"],
       "lowest priority first, then highest weight; duplicates dropped")
expect(DomainControllers.order([]).isEmpty, "no records")
// RDATA for "0 100 389 dc1.laps.test."
let rdata : [UInt8] = [0, 0, 0, 100, 1, 133, 3] + Array("dc1".utf8) + [4] + Array("laps".utf8) + [4] + Array("test".utf8) + [0]
let parsed = rdata.withUnsafeBytes { DomainControllers.parse($0) }
expect(parsed?.priority == 0 && parsed?.weight == 100 && parsed?.target == "dc1.laps.test", "SRV RDATA is parsed")
expect([UInt8]([0, 0, 0, 1, 1, 133, 9, 65]).withUnsafeBytes { DomainControllers.parse($0) } == nil, "a truncated RDATA is rejected")
// A real lookup through the system resolver (no answer expected for this name).
expect(DomainControllers.query("_ldap._tcp.dc._msdcs.invalid", timeout: 3).isEmpty, "a lookup with no answer returns nothing")

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------------------------- //
// | Writability and the fallback   | //
// ---------------------------------- //
// Fake domain controllers: one that refuses writes stands for an RODC.      //
struct Refused: Error { let why: String }
final class FakeDC: ADBackend {
    let name : String
    let followsBinding : Bool
    let refuses : Bool
    /// Like a Samba RODC: a write that changes nothing is accepted.
    let acceptsNoChange : Bool
    /// Set for a DC reached directly (LDAP); nil for Open Directory.
    let server : String?
    var values : [String: String]
    var writes : [(String, String)] = []
    var description : String { name }
    init(_ name: String, followsBinding: Bool = false, refuses: Bool = false,
         acceptsNoChange: Bool = false, ldap: Bool = false,
         values: [String: String] = [:]) {
        self.name = name; self.followsBinding = followsBinding
        self.refuses = refuses; self.acceptsNoChange = acceptsNoChange
        self.server = ldap ? name : nil
        self.values = values
    }
    func value(_ attribute: String) -> Any? { values[attribute] }
    func write(_ attribute: String, _ value: String) throws {
        if refuses && !(acceptsNoChange && values[attribute] == value) {
            throw Refused(why: "\(name) is read-only")
        }
        writes.append((attribute, value)); values[attribute] = value
    }
}
let fakeBinding = ADBinding(nodeName: "/Active Directory/LAPS", domain: "laps.test",
                            trustAccount: "CIMAC42$")
let expAttrs = ["ms-Mcs-AdmPwdExpirationTime", "msLAPS-PasswordExpirationTime"]
let why : (Error) -> String = { ($0 as? Refused)?.why ?? "\($0)" }

// 1. The bound DC takes the write: nothing else is asked.
var asked = 0
let bound1 = FakeDC("bound", followsBinding: true,
                    values: ["ms-Mcs-AdmPwdExpirationTime": "134000000000000000"])
let c1 = ADComputer(backend: bound1, binding: fakeBinding)
let r1 = Writability.ensure(c1, attributes: expAttrs, placeholder: "0",
                            candidates: { asked += 1; return ["dc1"] },
                            open: { _ in FakeDC("unused") }, explain: why)
expect(r1 == .writable && asked == 0 && (c1.backend as? FakeDC) === bound1,
       "a writable bound DC is kept; DNS is never asked")
expect(bound1.writes.map { $0.1 } == ["134000000000000001", "134000000000000000", "0"],
       "a real change (time + 1) then the time put back; a missing one gets the placeholder")
expect(bound1.values["ms-Mcs-AdmPwdExpirationTime"] == "134000000000000000",
       "the expiration ends where it started")

// 2. The bound DC is an RODC: the first candidate that takes the write wins.
let rodc2 = FakeDC("rodc2", refuses: true)
let dc1 = FakeDC("dc1", values: ["ms-Mcs-AdmPwdExpirationTime": "135000000000000000"])
var opened : [String] = []
let c2 = ADComputer(backend: FakeDC("rodc1", followsBinding: true, refuses: true),
                    binding: fakeBinding)
let r2 = Writability.ensure(c2, attributes: expAttrs, placeholder: "0",
                            candidates: { ["unreachable", "rodc2", "dc1", "dc9"] },
                            open: { server in
                                opened.append(server)
                                switch server {
                                case "rodc2": return rodc2
                                case "dc1": return dc1
                                default: throw Refused(why: "\(server) can't be reached")
                                }
                            }, explain: why)
expect(r2 == .switched(server: "dc1", refusal: "rodc1 is read-only",
                       skipped: [.init(server: "unreachable", reason: "unreachable can't be reached"),
                                 .init(server: "rodc2", reason: "rodc2 is read-only")]),
       "an RODC binding falls back to the first DC that takes the write, noting the others")
expect(opened == ["unreachable", "rodc2", "dc1"], "candidates are tried in order, stopping at the first that works")
expect((c2.backend as? FakeDC) === dc1, "the computer now reads and writes through that DC")
expect(dc1.writes.map { $0.1 } == ["135000000000000001", "135000000000000000", "0"],
       "the fallback DC's own values are written back, not the RODC's")
try? c2.write("ms-Mcs-AdmPwd", "new")
expect(dc1.values["ms-Mcs-AdmPwd"] == "new", "later writes go to the fallback DC")

// 2b. An RODC that accepts a write changing nothing (Samba) is still caught.
let samba = FakeDC("rodc1", refuses: true, acceptsNoChange: true,
                   values: ["ms-Mcs-AdmPwdExpirationTime": "134000000000000000",
                            "msLAPS-PasswordExpirationTime": "134000000000000000"])
let rs = Writability.ensure(ADComputer(backend: samba, binding: fakeBinding),
                            attributes: expAttrs, placeholder: "0",
                            candidates: { [] }, open: { _ in samba }, explain: why)
expect(rs == .refused(reason: "rodc1 is read-only"),
       "an RODC that accepts a no-change write is refused: the check changes the time")

// 2c. Open Directory couldn't reach AD, so an RODC was picked from DNS; it
// refuses, and the fallback moves on without trying it again.
let dcw = FakeDC("dcw", ldap: true)
var opened2c : [String] = []
let c2c = ADComputer(backend: FakeDC("rodc1", followsBinding: true, refuses: true, ldap: true),
                     binding: fakeBinding)
let r2c = Writability.ensure(c2c, attributes: expAttrs, placeholder: "0",
                             candidates: { ["dc1", "rodc1", "dcw"] },
                             open: { server in
                                 opened2c.append(server)
                                 if server == "dcw" { return dcw }
                                 throw Refused(why: "\(server) can't be reached")
                             }, explain: why)
expect(r2c == .switched(server: "dcw", refusal: "rodc1 is read-only",
                        skipped: [.init(server: "dc1", reason: "dc1 can't be reached")]),
       "a read-only DC picked from DNS falls back to the next writable one")
expect(opened2c == ["dc1", "dcw"], "the DC already in use isn't tried again")
expect((c2c.backend as? FakeDC) === dcw, "the computer now uses dcw")

// 3. A DC macOSLAPS chose (PreferredDC) refuses: no fallback, DNS isn't asked.
asked = 0
let c3 = ADComputer(backend: FakeDC("rodc1", refuses: true), binding: fakeBinding)
let r3 = Writability.ensure(c3, attributes: expAttrs, placeholder: "0",
                            candidates: { asked += 1; return ["dc1"] },
                            open: { _ in dc1 }, explain: why)
expect(r3 == .refused(reason: "rodc1 is read-only") && asked == 0,
       "a refusing PreferredDC stops the run without trying other DCs")

// 4. Nothing takes the write.
let c4 = ADComputer(backend: FakeDC("rodc1", followsBinding: true, refuses: true),
                    binding: fakeBinding)
let r4 = Writability.ensure(c4, attributes: expAttrs, placeholder: "0",
                            candidates: { ["rodc2"] }, open: { _ in rodc2 }, explain: why)
expect(r4 == .noWritableDC(refusal: "rodc1 is read-only",
                           skipped: [.init(server: "rodc2", reason: "rodc2 is read-only")]),
       "no writable DC: every refusal is reported")
let r5 = Writability.ensure(c4, attributes: expAttrs, placeholder: "0",
                            candidates: { [] }, open: { _ in rodc2 }, explain: why)
expect(r5 == .noWritableDC(refusal: "rodc1 is read-only", skipped: []),
       "no DCs in DNS: reported as no writable DC")
expect((c4.backend as? FakeDC)?.name == "rodc1", "the computer keeps its backend when nothing works")

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

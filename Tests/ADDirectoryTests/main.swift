/*
===============================================================================
 macOSLAPS | Tests | ADDirectoryTests/main.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-17
 Updated:   2026-11-17

 Purpose:
     Unit tests for the LDAP helpers in
     macOSLAPS/Password Tools/ADDirectory.swift: reading ldapsearch
     output, writing a change, escaping a search filter, and reading and
     ordering the domain controllers DNS returns. No domain, Xcode project or root
     needed.

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

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

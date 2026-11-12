/*
===============================================================================
 macOSLAPS | Tests | MDMAccountsTests/main.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-12
 Updated:   2026-11-12

 Purpose:
     Unit tests for MDMAccountsParser
     (macOSLAPS/Extensions/MDMAccountsParser.swift): the
     AutoSetupAdminAccounts list from mdmclient QueryDeviceInformation and
     the enrollment state from profiles status. No Xcode project or root
     needed.

 Usage:
     swiftc macOSLAPS/Extensions/MDMAccountsParser.swift \
         Tests/MDMAccountsTests/main.swift -o mdm-tests
     ./mdm-tests
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    New file.
                        claude
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------- //
// | Checks | //
// ---------- //
// Counting checks and failures.                                             //
var failures = 0
func expect(_ ok: Bool, _ message: String) { if !ok { failures += 1; print("FAIL: \(message)") } else { print("PASS: \(message)") } }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------- //
// | Sample output | //
// ----------------- //
// Shaped like mdmclient QueryDeviceInformation on macOS 26 (reported by     //
// Joshua, 2026-11-12), with the list filled in or broken.                   //
func sample(_ accounts: String, extra: String = "") -> String {
    """
    === CPF_GetInstalledProfiles === (<Device>)
    Number of <Device> profiles found: 12 (Filtered: 0)
    Daemon response: {
        QueryResponses =     {
            ActiveManagedUsers =         (
                "6E39891B-C387-491A-B8BE-F84175E42A52"
            );
            AutoSetupAdminAccounts = \(accounts);
            AvailableDeviceCapacity = 1390;
            AwaitingConfiguration = 0;
            BatteryLevel = "0.8";
            BluetoothMAC = "FC:B2:14:CD:33:F6";
            BuildVersion = 26B123;
            DeviceCapacity = 1995;\(extra)
        };
    }
    """
}
let one = """
(
                    {
                    GUID = "851D63DB-068A-4FCD-B650-709144FE6E20";
                    shortName = ladmin;
                }
            )
"""

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------- //
// | Parsing | //
// ----------- //
// Empty, one, two, broken and missing lists.                                //
expect(MDMAccountsParser.parse(sample("        (\n        )")) == [], "empty list (Joshua's Mac) parses as []")
expect(MDMAccountsParser.parse(sample(one)) == [AutoSetupAdmin(guid: "851D63DB-068A-4FCD-B650-709144FE6E20", shortName: "ladmin")], "one entry")
let two = "( { GUID = \"A-1\"; shortName = \"it admin\"; }, { guid = B-2; ShortName = helpdesk; } )"
expect(MDMAccountsParser.parse(sample(two)) == [AutoSetupAdmin(guid: "A-1", shortName: "it admin"), AutoSetupAdmin(guid: "B-2", shortName: "helpdesk")], "two entries, key case ignored")
// A value the whole-output parse can't handle (an unquoted date): only the array is parsed.
let withDate = sample(one, extra: "\n            LastCloudBackupDate = 2026-11-12 14:00:00 +0000;")
expect(MDMAccountsParser.parse(withDate)?.first?.shortName == "ladmin", "falls back to the array alone when the whole output won't parse")
expect(MDMAccountsParser.parse(sample("( { shortName = ladmin; } )")) == nil, "an entry without a GUID makes the list unreadable")
expect(MDMAccountsParser.parse(sample("( \"ladmin\" )")) == nil, "an entry that isn't a dictionary makes the list unreadable")
expect(MDMAccountsParser.parse(sample("( { GUID = \"(x)\"; shortName = \"a)b\"; } )")) == [AutoSetupAdmin(guid: "(x)", shortName: "a)b")], "parentheses inside quotes")
// Real output from a Penn State Mac with a Jamf PreStage admin (2026-11-12, via Joshua),
// once with straight quotes as mdmclient prints them and once as pasted (curly quotes).
let psu = """
Daemon response: {
    QueryResponses =     {
        AutoSetupAdminAccounts =     (
                    {
                GUID = "22F40CA2-8731-4D62-AC31-DAD9C40D1A79";
                shortName = cetc;
            }
        );
        AvailableDeviceCapacity = 35;
        AwaitingConfiguration = 0;
        BatteryLevel = 1;
    };
}
"""
let cetc = [AutoSetupAdmin(guid: "22F40CA2-8731-4D62-AC31-DAD9C40D1A79", shortName: "cetc")]
expect(MDMAccountsParser.parse(psu) == cetc, "real PreStage admin output (cetc)")
expect(MDMAccountsParser.parse(psu.replacingOccurrences(of: "\"22F40CA2-8731-4D62-AC31-DAD9C40D1A79\"", with: "\u{201C}22F40CA2-8731-4D62-AC31-DAD9C40D1A79\u{201D}")) == cetc, "the same with curly quotes from a paste")
let noKey = sample(one).replacingOccurrences(of: "AutoSetupAdminAccounts", with: "SomethingElse")
expect(MDMAccountsParser.parse(noKey) == nil, "no AutoSetupAdminAccounts key: unreadable, not empty")
expect(MDMAccountsParser.parse("") == nil, "no output: unreadable")
expect(MDMAccountsParser.parse("Error: not authorized") == nil, "an error message: unreadable")

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------- //
// | Enrollment | //
// -------------- //
// profiles status -type enrollment.                                         //
expect(MDMEnrollment.parse("Enrolled via DEP: Yes\nMDM enrollment: Yes (User Approved)\nMDM server: https://x") == true, "enrolled")
expect(MDMEnrollment.parse("Enrolled via DEP: No\nMDM enrollment: No") == false, "not enrolled")
expect(MDMEnrollment.parse("profiles: error") == nil, "unknown")

print("\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)

/*
===============================================================================
 macOSLAPS | Extensions | AdminGroup.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-11
 Updated:   2026-11-17

 Purpose:
     Admin group protection. Anyone who knows the managed admin's password
     can make their own account an admin in Users & Groups; macOSLAPS
     can't stop that as it happens, but catches it on its next run. Only
     the managed admin, root and the accounts or groups in ApprovedAdmins
     may stay admin.

 Settings:
     AdminGroupPolicy  auto (default): remove unapproved admins, unless an
                       elevation tool is installed, then report only
                       report: only list them in -status and the log
                       enforce: remove them even with an elevation tool
     ApprovedAdmins    short names, or group:<name> for a group's members
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-17   joshua    Elevation tools count only when signed (SAP
                        claude    Privileges and Jamf Connect by their team),
                                  so an empty folder can't switch auto to
                                  report only.
 4.0.0     2026-11-12   joshua    New file. Admins your MDM created during
                        claude    Automated Device Enrollment are never
                                  removed; nobody is removed when an enrolled
                                  Mac's list of them can't be read.
===============================================================================
*/

import Foundation
import OpenDirectory
import Security

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------ //
// | Settings | //
// ------------ //
// AdminGroupPolicy and ApprovedAdmins, from the MDM profile.                //
enum AdminGroup {
    /// auto (default) | report | enforce.
    static var policy : String {
        let raw = (GetPreference(preference_key: "AdminGroupPolicy") as? String ?? "auto").lowercased()
        switch raw {
        case "auto", "report", "enforce": return raw
        default:
            laps_log.print("Unknown AdminGroupPolicy \"\(raw)\"; using auto.", .warn)
            return "auto"
        }
    }

    /// ApprovedAdmins: short names, or group:<name> for members of a group.
    static var approvedEntries : [String] {
        (GetPreference(preference_key: "ApprovedAdmins") as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------------------- //
// | Who is in the admin group | //
// ----------------------------- //
// Direct members from the local node; nested groups are only reported.      //
    private static func groupAttribute(_ attribute: String) -> [String] {
        let result = Shell.execute(launchPath: "/usr/bin/dscl",
                                   arguments: ["-plist", ".", "-read", "/Groups/admin", attribute], timeout: 30)
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return []
        }
        return plist["dsAttrTypeStandard:\(attribute)"] as? [String] ?? []
    }

    static func directMembers() -> [String] { groupAttribute("GroupMembership") }
    static func nestedGroupCount() -> Int { groupAttribute("NestedGroups").count }

    static func isMember(_ user: String, of group: String) -> Bool {
        Shell.execute(launchPath: "/usr/sbin/dseditgroup",
                      arguments: ["-o", "checkmember", "-m", user, group], timeout: 30).status == 0
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------- //
// | Approved admins | //
// ------------------- //
// root and the managed admin always; then ApprovedAdmins, by name or by     //
// group.                                                                    //
    static func isApproved(_ user: String) -> Bool {
        let name = user.lowercased()
        if name == "root" || name == Constants.local_admin.lowercased() { return true }
        // Created by the MDM during Automated Device Enrollment: never removed.
        if MDMAccounts.isCreatedByMDM(user) { return true }
        for entry in approvedEntries {
            if entry.lowercased().hasPrefix("group:") {
                let group = String(entry.dropFirst("group:".count))
                if !group.isEmpty && isMember(user, of: group) { return true }
            } else if entry.lowercased() == name {
                return true
            }
        }
        return false
    }

    /// Admins that are neither the managed admin, root nor in ApprovedAdmins.
    static func unapproved() -> [String] {
        directMembers().filter { !isApproved($0) }
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------- //
// | Elevation tools | //
// ------------------- //
// With one of these installed, users become admin on purpose, so auto only  //
// reports.                                                                  //
    /// Each tool's app, and the team that must have signed it (nil: any Developer ID
    /// or App Store signature; the team IDs of the last two couldn't be confirmed).
    static let elevationTools : [(name: String, path: String, team: String?)] = [
        ("SAP Privileges", "/Applications/Privileges.app", "7R5ZEU67FQ"),
        ("Jamf Connect", "/Applications/Jamf Connect.app", "483DWKW443"),
        ("Admin By Request", "/Applications/Admin By Request.app", nil),
        ("Make Me Admin", "/Applications/Make Me Admin.app", nil),
    ]

    /// The first tool installed and properly signed. An empty folder or a renamed copy
    /// of some other app doesn't count, so it can't switch auto to report only.
    static func elevationTool() -> String? {
        elevationTools.first { tool in
            FileManager.default.fileExists(atPath: tool.path) && signed(tool.path, team: tool.team)
        }?.name
    }

    private static func signed(_ path: String, team: String?) -> Bool {
        var code : SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let app = code else { return false }
        let text = "anchor apple generic" + (team.map { " and certificate leaf[subject.OU] = \"\($0)\"" } ?? "")
        var requirement : SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }
        // The executable and Info.plist are checked; skipping every resource keeps this fast.
        return SecStaticCodeCheckValidity(app, SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources)), req) == errSecSuccess
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------------------- //
// | Checking and enforcing | //
// -------------------------- //
// Runs on every rotation run. Removes unapproved admins only when the       //
// policy says so and macOSLAPS holds a password that works for the managed  //
// admin right now, so the Mac is never left without a working admin.        //
    static func check() {
        let unapproved = unapproved()
        if nestedGroupCount() > 0 {
            laps_log.print("The admin group contains nested groups; their members are not checked or changed.", .info)
        }
        guard !unapproved.isEmpty else { return }
        let list = unapproved.joined(separator: ", ")
        let tool = elevationTool()
        let mode = policy
        if mode == "report" || (mode == "auto" && tool != nil) {
            let why = mode == "report" ? "AdminGroupPolicy is report" : "\(tool!) is installed"
            laps_log.print("Admins not in ApprovedAdmins: \(list). Not removed (\(why)).", .warn)
            return
        }
        if let why = MDMAccounts.unsafeToRemoveAdmins {
            laps_log.print("Admins not in ApprovedAdmins: \(list). Not removed: the list of admin accounts your MDM created can't be read (\(why)), so macOSLAPS can't tell them apart.", .warn)
            return
        }
        guard managedAdminWorks() else {
            laps_log.print("Admins not in ApprovedAdmins: \(list). Not removed: macOSLAPS has no verified password for \(Constants.local_admin), so removing them could leave this Mac without a working admin.", .warn)
            return
        }
        var removed : [String] = []
        for user in unapproved {
            _ = Shell.execute(launchPath: "/usr/sbin/dseditgroup",
                              arguments: ["-o", "edit", "-d", user, "-t", "user", "admin"], timeout: 30)
            if isMember(user, of: "admin") {
                laps_log.print("Could not remove \(user) from the admin group.", .error)
            } else {
                laps_log.print("Removed \(user) from the admin group: not in ApprovedAdmins (AdminGroupPolicy \(mode)).", .warn)
                removed.append(user)
            }
        }
        guard !removed.isEmpty else { return }
        let stamp = RunState.iso.string(from: Date())
        let history = (RunState.arrayValue("demotedAdmins") + removed.map { "\($0) \(stamp)" }).suffix(20)
        RunState.set(["demotedAdmins": Array(history)])
    }

    /// The managed admin exists, is an admin, and the stored password works for it now.
    static func managedAdminWorks() -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: nil),
              isMember(Constants.local_admin, of: "admin") else { return false }
        guard let stored = KeychainService.current else { return false }
        return RunState.storedPasswordWorks(stored.password, created: stored.created, record: record, force: true)
    }
}

/*
===============================================================================
 macOSLAPS | Extensions | MDMAccounts.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-12
 Updated:   2026-11-12

 Purpose:
     Which local admin accounts an MDM created. During Automated Device
     Enrollment the MDM can have Setup Assistant create an admin with
     Apple's AccountConfiguration command (the Jamf PreStage admin, the
     Intune ADE admin, the Iru Auto Admin and others). macOS keeps a
     record of it, which root reads with mdmclient QueryDeviceInformation
     (AutoSetupAdminAccounts). An account counts only when both its
     GeneratedUID and its short name match an entry. Admin group
     protection never removes these accounts and removes nobody when an
     enrolled Mac's list can't be read; AllowMDMManagedAccount decides
     whether macOSLAPS may manage one.

 Settings:
     AllowMDMManagedAccount  true (default): manage an MDM-created
                             admin, with a warning; false: refuse
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
// -------------------------------- //
// | Reading the list on this Mac | //
// -------------------------------- //
// Runs mdmclient and profiles once per run (root only).                     //
enum MDMAccounts {
    enum Listing {
        case listed([AutoSetupAdmin])
        case unreadable(String)
    }

    private static var cachedListing : Listing?
    private static var cachedEnrolled : Bool??

    static var listing : Listing {
        if let l = cachedListing { return l }
        let l : Listing
        if getuid() != 0 {
            l = .unreadable("needs root")
        } else if !FileManager.default.isExecutableFile(atPath: "/usr/libexec/mdmclient") {
            l = .unreadable("/usr/libexec/mdmclient not found")
        } else {
            let r = Shell.execute(launchPath: "/usr/libexec/mdmclient", arguments: ["QueryDeviceInformation"], timeout: 30)
            if r.timedOut { l = .unreadable("mdmclient timed out") }
            else if let list = MDMAccountsParser.parse(r.output) { l = .listed(list) }
            else { l = .unreadable("mdmclient's output has no readable AutoSetupAdminAccounts list") }
        }
        cachedListing = l
        return l
    }

    /// true when profiles says the Mac is MDM-enrolled; nil when it can't tell.
    static var enrolled : Bool? {
        if let e = cachedEnrolled { return e }
        let r = Shell.execute(launchPath: "/usr/bin/profiles", arguments: ["status", "-type", "enrollment"], timeout: 30)
        let e = r.timedOut ? nil : MDMEnrollment.parse(r.output)
        cachedEnrolled = .some(e)
        return e
    }

    /// The list can't be trusted on this run: an MDM (or unknown) enrollment and no readable list.
    static var unsafeToRemoveAdmins : String? {
        guard case .unreadable(let why) = listing, enrolled != false else { return nil }
        return why
    }

    /// Short names of local accounts an MDM created (both GUID and short name match).
    static func createdByMDM() -> [String] {
        guard case .listed(let list) = listing else { return [] }
        return list.filter { matches($0) }.map { $0.shortName }
    }

    static func isCreatedByMDM(_ user: String) -> Bool {
        guard case .listed(let list) = listing else { return false }
        return list.contains { $0.shortName.lowercased() == user.lowercased() && matches($0) }
    }

    private static func matches(_ entry: AutoSetupAdmin) -> Bool {
        let r = Shell.execute(launchPath: "/usr/bin/dscl",
                              arguments: [".", "-read", "/Users/\(entry.shortName)", "GeneratedUID"], timeout: 30)
        guard r.status == 0 else { return false }
        let guid = r.output.replacingOccurrences(of: "GeneratedUID:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return guid.caseInsensitiveCompare(entry.guid) == .orderedSame
    }

    /// Status text for -status: "none", "listed", or why the list couldn't be read.
    static var listState : String {
        switch listing {
        case .listed(let l): return l.isEmpty ? "none" : "listed"
        case .unreadable(let why): return enrolled == false ? "not enrolled" : "unreadable: \(why)"
        }
    }

    /// AllowMDMManagedAccount: may macOSLAPS manage the MDM-created admin? (default true)
    static var allowManagingMDMAccount : Bool {
        GetPreference(preference_key: "AllowMDMManagedAccount") as? Bool ?? true
    }

    /// Before a rotation: refuse (AllowMDMManagedAccount false) or warn once a day.
    static func checkManagedAccount() {
        guard isCreatedByMDM(Constants.local_admin) else { return }
        guard allowManagingMDMAccount else {
            laps_log.print("Not rotating: \(Constants.local_admin) was created by your MDM during Automated Device Enrollment, and AllowMDMManagedAccount is false. The MDM can change this account's password itself; let one of them own it.", .error)
            exit(1)
        }
        let last = RunState.value("mdmAccountWarnedAt").flatMap { RunState.iso.date(from: $0) }
        if last == nil || Date().timeIntervalSince(last!) > 86400 {
            laps_log.print("\(Constants.local_admin) was created by your MDM during Automated Device Enrollment, so the MDM can change its password too (MDM LAPS, SetAutoAdminPassword). If your MDM's LAPS is on for this account, the two will conflict: let one of them own it. macOSLAPS stops rotating if the password is changed outside it. Set AllowMDMManagedAccount false to refuse instead.", .warn)
            RunState.set(["mdmAccountWarnedAt": RunState.iso.string(from: Date())])
        }
    }
}

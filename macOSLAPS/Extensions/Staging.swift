///
///  Staging.swift
///  macOSLAPS
///
///  Created November 10, 2026
///
///  Staged rotation: the MDM gets the next password before the account uses it.
///
///  1. When the password is due (or -resetPassword), a new password is stored as
///     *pending* in its own keychain item ("macOSLAPS-pending"). The account is not
///     changed yet.
///  2. -escrow prints the current and the pending password. Each successful -escrow
///     with a pending password counts as one export.
///  3. The next run applies the pending password once it has been exported
///     EscrowConfirmations times (default 2), or right away when the InventoryHook
///     ran inventory successfully and that inventory exported it.
///  4. Applying = change the account to the pending password, store it as the current
///     one (and in AD), then remove the pending item. A marker written before the
///     account changes lets the next run finish an apply that was interrupted
///     (power loss, SIGKILL).
///
///  StagedRotation: auto (default) | on | off.
///    auto: staging is used only when -escrow has run on this Mac in the last 14 days,
///          i.e. the MDM collects the pending password. Macs whose inventory still
///          uses the older -getPassword scripts keep rotating immediately.

import Foundation
import OpenDirectory

enum Staging {
    static let service = "macOSLAPS-pending"
    static let autoWindow : TimeInterval = 14 * 24 * 60 * 60

    static var mode : String {
        let raw = (GetPreference(preference_key: "StagedRotation") as? String ?? "auto").lowercased()
        switch raw {
        case "on", "true", "yes", "1": return "on"
        case "off", "false", "no", "0": return "off"
        default: return "auto"
        }
    }

    /// Whether new passwords are staged on this Mac right now.
    static var active : Bool {
        switch mode {
        case "on": return true
        case "off": return false
        default:
            guard let last = RunState.value("lastEscrow").flatMap(RunState.iso.date(from:)) else { return false }
            return Date().timeIntervalSince(last) < autoWindow
        }
    }

    static var confirmationsNeeded : Int {
        max(1, GetPreference(preference_key: "EscrowConfirmations") as? Int ?? 2)
    }

    /// The pending password and its creation date, if one is staged.
    static func pending() -> (password: String, created: String?)? {
        let (password, created) = KeychainService.loadPassword(service: service)
        guard let pw = password else { return nil }
        return (pw, (created == "Not Found") ? nil : created)
    }

    static var exports : Int { RunState.intValue("pendingExports") }

    /// Pending password exported enough times (or confirmed by a successful hook).
    static var confirmed : Bool {
        exports >= confirmationsNeeded || RunState.value("pendingHookConfirmed") == "yes"
    }

    /// Stores `password` as the pending password (replacing any older pending one).
    static func stage(_ password: String) -> Bool {
        let status = KeychainService.savePassword(service: service, account: "LAPS Pending Password", data: password)
        guard status == noErr else {
            laps_log.print("Unable to store the pending password in the keychain (OSStatus \(status)). Nothing was changed.", .error)
            return false
        }
        RunState.set(["pendingExports": 0, "pendingStaged": RunState.iso.string(from: Date())],
                     remove: ["pendingHookConfirmed", "applying"])
        return true
    }

    /// Called by -escrow after it printed a payload that included the pending password.
    static func noteExported() {
        RunState.set(["pendingExports": exports + 1, "lastEscrow": RunState.iso.string(from: Date())])
    }
    /// Called by -escrow after any successful output.
    static func noteEscrowRan() {
        RunState.set(["lastEscrow": RunState.iso.string(from: Date())])
    }

    /// Marks that the account is about to be changed to the pending password.
    static func beginApply() { RunState.set(["applying": "yes"]) }

    /// After the pending password is the stored current one: remove it and the counters.
    static func finishApply() {
        _ = KeychainService.deleteExport(service: service)
        RunState.set([:], remove: ["applying", "pendingExports", "pendingStaged", "pendingHookConfirmed"])
    }

    static var interruptedApply : Bool { RunState.value("applying") == "yes" }

    /// Runs the InventoryHook after staging; if it ran inventory successfully and that
    /// inventory exported the pending password, the pending password counts as confirmed.
    static func runHookAndCheck() {
        let before = exports
        let trusted = InventoryHook.confirmsExports
        let succeeded = InventoryHook.run(reason: "staging a new password")
        if succeeded && trusted && exports > before {
            RunState.set(["pendingHookConfirmed": "yes"])
            laps_log.print("The inventory hook collected the pending password.", .info)
        }
    }
}

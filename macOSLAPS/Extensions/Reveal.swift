/*
===============================================================================
 macOSLAPS | Extensions | Reveal.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-11
 Updated:   2026-11-17

 Purpose:
     Device mode (RetrievalMode device): the MDM gets a reveal code
     instead of the password, so the password never leaves the Mac.
     Someone with the code reveals the password on the Mac (the app, or
     macOSLAPS -reveal) to elevate; the same code works again until the
     rotation. After RevealGracePeriod the admin is logged out (if it has
     a session) and the password rotates with a new code, exactly at the
     deadline. -expireIn sets the same deadline in escrow mode.

 Settings:
     RetrievalMode      escrow (default) | device
     RevealGracePeriod  hours the password works after a reveal, 0-24 (4)
     RevealAction       rotateAndLogout (default) | rotate
     ADRevealCode       device mode with AD: write the code to AD (false)

 Used by:
     main.swift (-reveal, -expireIn, the rotation run), Service.swift,
     Escrow.swift, ADPasswordTools.swift, Status.swift, RunState.swift
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-17   joshua    After five wrong codes reveals wait (1
                        claude    minute, doubling, at most 1 hour) instead of
                                  locking until the rotation; -reason is
                                  logged on one line; one function prints a
                                  reveal.
 4.0.0     2026-11-12   joshua    New file. A code reveals the password until
                        claude    the next rotation (Joshua: re-elevating
                                  during the grace period needs no new code);
                                  the rotation issues a new one. The check run
                                  waits for a near deadline so the rotation
                                  happens on time; -reason records why a
                                  password was revealed; deadline.plist tells
                                  the menu bar agent when it rotates;
                                  deadlineSetAt records when a deadline was
                                  set. "Will be logged out" is shown only
                                  when the managed admin is logged in.
                        joshua    ADRevealCode: a rotation issues the new
                        claude    code before writing AD, so AD holds the
                                  live code (it held the code just burned).
===============================================================================
*/

import Foundation
import OpenDirectory
import SystemConfiguration

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------ //
// | Settings | //
// ------------ //
// RetrievalMode, RevealGracePeriod, RevealAction and ADRevealCode.          //
enum Reveal {
    /// RetrievalMode device: the MDM gets a one-time reveal code, never the password.
    static var deviceMode : Bool {
        (GetPreference(preference_key: "RetrievalMode") as? String ?? "escrow").lowercased() == "device"
    }
    /// Hours the password keeps working after a reveal (0 = no rotation after a reveal).
    static var graceHours : Int {
        min(24, max(0, GetPreference(preference_key: "RevealGracePeriod") as? Int ?? 4))
    }
    /// rotateAndLogout (default) or rotate.
    static var action : String {
        (GetPreference(preference_key: "RevealAction") as? String ?? "rotateAndLogout").lowercased() == "rotate"
            ? "rotate" : "rotateAndLogout"
    }
    static var writesCodeToAD : Bool {
        Constants.method == "AD" && (GetPreference(preference_key: "ADRevealCode") as? Bool ?? false)
    }
    static let maxFailures = 5

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------- //
// | Reveal codes | //
// ---------------- //
// 16 characters in groups of four, from letters and digits without          //
// look-alikes (no 0/O, 1/I/L). Typed in any case, with or without dashes.   //
// Kept in the System keychain next to the password.                         //
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func newCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Compares without stopping at the first difference.
    static func matches(_ entered: String, _ stored: String) -> Bool {
        let a = Array(normalize(entered).utf8), b = Array(normalize(stored).utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The current code; a new one is made when there is none (device mode only).
    static func currentCode(create: Bool = true) -> String? {
        if let existing = KeychainService.load(service: KeychainNames.reveal)?.password { return existing }
        guard create, deviceMode else { return nil }
        return replaceCode(reason: "first reveal code")
    }

    /// Burns the current code and stores a new one. Clears a lockout.
    @discardableResult
    static func replaceCode(reason: String) -> String? {
        let code = newCode()
        let status = KeychainService.savePassword(service: KeychainNames.reveal, account: Constants.local_admin, data: code)
        guard status == noErr else {
            laps_log.print("Unable to store a new reveal code (OSStatus \(status)).", .error)
            return nil
        }
        RunState.set(["revealCodeSet": RunState.iso.string(from: Date()), "revealFailures": 0,
                      "adRevealCodeOutdated": writesCodeToAD ? "yes" : "no"], remove: ["revealRetryAt"])
        laps_log.print("New reveal code for \(Constants.local_admin) (\(reason)). The MDM collects it with -escrow.", .info)
        return code
    }

    static var failures : Int { RunState.intValue("revealFailures") }

    /// After maxFailures wrong codes in a row, reveals wait: 1 minute, then twice as
    /// long after each further wrong code, at most an hour. A correct code or a
    /// rotation starts over. A wait, not a lock, so a user typing wrong codes can't
    /// keep IT from revealing (a code has about 79 bits, so guessing is hopeless).
    static func backoff(afterFailures count: Int) -> TimeInterval? {
        guard count >= maxFailures else { return nil }
        return min(3600, 60 * pow(2, Double(min(count - maxFailures, 6))))
    }
    /// When reveals are allowed again, while waiting.
    static var retryAt : Date? {
        RunState.value("revealRetryAt").flatMap(RunState.iso.date(from:)).flatMap { $0 > Date() ? $0 : nil }
    }
    static var locked : Bool { retryAt != nil }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------ //
// | Deadline | //
// ------------ //
// After a reveal (or -expireIn) the password works until rotatesAt. The     //
// check run waits for a deadline that comes before its next scheduled run,  //
// then logs the admin out (RevealAction rotateAndLogout) and rotates; a     //
// rotation clears the deadline and, in device mode, issues a new code.      //
    static var rotatesAt : Date? { RunState.value("rotatesAt").flatMap(RunState.iso.date(from:)) }
    static var deadlinePassed : Bool { rotatesAt.map { $0 <= Date() } ?? false }

    /// Called by the rotation run before anything else rotates.
    static func endOfGraceIfDue() {
        guard deadlinePassed else { return }
        laps_log.print("The password for \(Constants.local_admin) was due to change at \(RunState.value("rotatesAt") ?? "?"). Rotating now.", .info)
        if action == "rotateAndLogout" { logOutManagedAdmin() }
        Constants.pw_reset = true
    }

    /// The check run, when not due: if the deadline falls before the next scheduled run,
    /// stay, sleep until it (rechecking the wall clock, so sleep and wake are fine), then
    /// start over as a fresh run, which rotates. Releases the run lock while waiting.
    static func waitForDeadlineIfSoon(window: TimeInterval = 95 * 60) {
        guard let first = rotatesAt, first > Date(), first.timeIntervalSinceNow < window else { return }
        laps_log.print("Waiting until \(Constants.dateFormatter.string(from: first)) to change the password for \(Constants.local_admin).", .info)
        RunLock.release()
        while true {
            guard let deadline = rotatesAt else { return }   // rotated by another run
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            Thread.sleep(forTimeInterval: min(30, left))
        }
        let path = AppBundle.launchPath ?? CommandLine.arguments[0]
        var argv : [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        execv(path, argv)
        laps_log.print("Could not restart macOSLAPS at the deadline (errno \(errno)); the next run rotates.", .error)
    }

    /// Non-secret, world-readable copy of the deadline for the menu bar agent (which runs as
    /// the user and can't read the root-only state): account, rotatesAt, action, reason,
    /// revealedAt. Removed when there is no deadline. Called whenever rotatesAt changes.
    static let deadlineFile = "/Library/Application Support/macOSLAPS/deadline.plist"
    static func publishDeadline() {
        guard getuid() == 0 else { return }
        let fm = FileManager.default
        guard let at = RunState.value("rotatesAt") else {
            try? fm.removeItem(atPath: deadlineFile)
            return
        }
        var info : [String: Any] = ["account": Constants.local_admin, "rotatesAt": at, "action": action,
                                    "reason": RunState.value("rotateReason") ?? "scheduled"]
        if let revealed = RunState.value("revealedAt") { info["revealedAt"] = revealed }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) else { return }
        try? fm.createDirectory(atPath: (deadlineFile as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: deadlineFile, contents: data, attributes: [.posixPermissions: 0o644])
    }

    /// After every successful rotation (RunState.record("rotated")).
    static func afterRotation() {
        RunState.set([:], remove: ["rotatesAt", "revealedAt", "rotateReason", "deadlineSetAt"])
        if deviceMode && !issuedForRotation { replaceCode(reason: "after rotation") }
    }

    /// Whether the managed admin has a GUI login session (the kind
    /// logOutManagedAdmin ends). Any user can ask; nil when it can't tell.
    static func managedAdminLoggedIn() -> Bool? {
        guard let entry = getpwnam(Constants.local_admin) else { return false }
        let uid = entry.pointee.pw_uid
        guard let store = SCDynamicStoreCreate(nil, "macOSLAPS" as CFString, nil, nil),
              let info = SCDynamicStoreCopyValue(store, "State:/Users/ConsoleUser" as CFString) as? [String: Any],
              let sessions = info["SessionInfo"] as? [[String: Any]] else { return nil }
        return sessions.contains {
            ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid ||
            ($0["kCGSSessionUserNameKey"] as? String) == Constants.local_admin
        }
    }

    /// The logout warning applies: rotateAndLogout and the admin is (or may be) logged in.
    static func logoutApplies(_ action: String) -> Bool {
        action == "rotateAndLogout" && managedAdminLoggedIn() != false
    }

    /// Ends the managed admin's login session, if it has one.
    static func logOutManagedAdmin() {
        guard let entry = getpwnam(Constants.local_admin) else { return }
        let uid = entry.pointee.pw_uid
        let domain = "gui/\(uid)"
        guard Shell.execute(launchPath: "/bin/launchctl", arguments: ["print", domain], timeout: 30).status == 0 else { return }
        laps_log.print("Logging out \(Constants.local_admin) (RevealAction rotateAndLogout).", .warn)
        _ = Shell.execute(launchPath: "/bin/launchctl", arguments: ["bootout", domain], timeout: 60)
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------- //
// | -reveal | //
// ----------- //
// Checks a code and, when it is right, shows the password and starts the    //
// grace period. The same code works again until the rotation (to elevate    //
// again); the rotation issues a new one. Every attempt is recorded; after   //
// five wrong ones in a row, reveals wait (1 minute, doubling, at most 1 h). //
    struct Result {
        let password: String
        let worksUntil: Date?
        let verified: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        case notDeviceMode, waiting(until: Date), noCode, wrongCode(left: Int), noPassword
        var description: String {
            switch self {
            case .notDeviceMode: return "Reveal codes are only used when RetrievalMode is device."
            case .waiting(let until): return "Too many wrong codes. Try again after \(Constants.dateFormatter.string(from: until))."
            case .noCode: return "There is no reveal code yet. It is created on the next macOSLAPS run."
            case .wrongCode(let left):
                return left > 0 ? "That code is not right. \(left) attempt(s) left before reveals have to wait."
                                : "That code is not right. Reveals have to wait a while before the next try."
            case .noPassword: return "macOSLAPS has no stored password for \(Constants.local_admin)."
            }
        }
    }

    /// Text from a user (a -reason) for the log: one line, no control characters.
    static func oneLine(_ text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
    }

    /// The shared check behind -reveal and the app.
    static func perform(code: String, who rawWho: String) -> Swift.Result<Result, Failure> {
        let who = oneLine(rawWho)
        guard deviceMode else { return .failure(.notDeviceMode) }
        if let until = retryAt { return .failure(.waiting(until: until)) }
        guard let stored = currentCode(create: false) else { return .failure(.noCode) }
        guard matches(code, stored) else {
            let count = failures + 1
            var values : [String: Any] = ["revealFailures": count]
            let wait = backoff(afterFailures: count)
            if let w = wait { values["revealRetryAt"] = RunState.iso.string(from: Date().addingTimeInterval(w)) }
            RunState.set(values)
            appendHistory("failed \(who)")
            laps_log.print("Wrong reveal code entered (\(count) in a row) by \(who).", .warn)
            if let w = wait {
                laps_log.print("Reveals wait \(Int(w / 60)) minute(s) after \(count) wrong codes in a row.", .error)
            }
            return .failure(.wrongCode(left: max(0, maxFailures - count)))
        }
        guard let stored = KeychainService.current else { return .failure(.noPassword) }
        let pw = stored.password, created = stored.created
        var verified = false
        if let node = try? ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)),
           let record = try? node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: nil) {
            verified = RunState.storedPasswordWorks(pw, created: created, record: record, force: true)
        }
        var until : Date? = nil
        if graceHours > 0 {
            let deadline = Date().addingTimeInterval(TimeInterval(graceHours) * 3600)
            until = rotatesAt.map { min($0, deadline) } ?? deadline   // a second reveal never extends it
        }
        var values : [String: Any] = ["revealedAt": RunState.iso.string(from: Date()), "rotateReason": "reveal",
                                      "revealFailures": 0]
        if let u = until {
            values["rotatesAt"] = RunState.iso.string(from: u)
            values["deadlineSetAt"] = RunState.preciseISO.string(from: Date())
        }
        RunState.set(values, remove: ["revealRetryAt"])
        appendHistory("revealed \(who)")
        laps_log.print("The password for \(Constants.local_admin) was revealed to \(who)" +
                       (until.map { "; it changes at \(Constants.dateFormatter.string(from: $0))." } ?? "."), .warn)
        // The code keeps working until the rotation: the password it reveals is already
        // exposed until then, so revealing it again (to elevate again) adds nothing.
        return .success(Result(password: pw, worksUntil: until, verified: verified))
    }

    static func appendHistory(_ entry: String) {
        let line = "\(RunState.iso.string(from: Date())) \(entry)"
        RunState.set(["revealHistory": Array((RunState.arrayValue("revealHistory") + [line]).suffix(20))])
    }

    /// The user at the console (who entered the code), for the log.
    static func consoleUser() -> String {
        (SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?).flatMap { $0 == "loginwindow" ? nil : $0 } ?? "root"
    }

    static func runCommand(code: String) -> Never {
        RunLock.acquire()
        let reason = argumentValue(after: "-reason") ?? ""
        switch perform(code: code, who: "\(consoleUser()) (command line)" + (reason.isEmpty ? "" : " (reason: \(reason.prefix(200)))")) {
        case .failure(let failure):
            laps_log.print(failure.description, .error)
            exit(1)
        case .success(let result):
            RunLock.release()
            Service.kickCheck()   // arms the deadline timer when the deadline is near
            printRevealed(password: result.password, worksUntil: result.worksUntil, verified: result.verified)
            exit(0)
        }
    }

    /// What -reveal prints, run as root or through the service.
    static func printRevealed(password: String, worksUntil: Date?, verified: Bool) {
        print("Local Admin Account: \(Constants.local_admin)")
        print("Password: \(password)")
        if let until = worksUntil {
            let minutes = Int(until.timeIntervalSinceNow / 60)
            print("Works until: \(Constants.dateFormatter.string(from: until)) (\(minutes / 60) h \(minutes % 60) min)")
            if logoutApplies(action) { print("\(Constants.local_admin) will be logged out at that time.") }
        }
        if !verified { print("Warning: this password did not work for \(Constants.local_admin) just now.") }
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------- //
// | -expireIn | //
// ------------- //
// Escrow or device mode: the password changes after the given time, e.g.    //
// 4h, 30m, 2h30m or 0 (next run). Same deadline, countdown and logout as a  //
// reveal.                                                                   //
    static func parseDuration(_ text: String) -> TimeInterval? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let hours = Double(t) { return hours * 3600 }
        var total : TimeInterval = 0, number = "", seen = false
        for c in t {
            if c.isNumber || c == "." { number.append(c); continue }
            guard let n = Double(number) else { return nil }
            switch c {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""; seen = true
        }
        return (number.isEmpty && seen) ? total : nil
    }

    static func expireIn(_ text: String) -> Never {
        guard let seconds = parseDuration(text), seconds >= 0, seconds <= 7 * 24 * 3600 else {
            laps_log.print("-expireIn needs a time such as 4h, 30m or 2h30m (at most 7 days).", .error)
            exit(64)
        }
        let deadline = Date().addingTimeInterval(seconds)
        RunState.set(["rotatesAt": RunState.iso.string(from: deadline), "rotateReason": "expireIn",
                      "deadlineSetAt": RunState.preciseISO.string(from: Date())])
        laps_log.print("The password for \(Constants.local_admin) changes at \(Constants.dateFormatter.string(from: deadline)) or on the first run after it.", .info)
        print("The password for \(Constants.local_admin) changes at \(Constants.dateFormatter.string(from: deadline)).")
        Service.kickCheck()
        exit(0)
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------------- //
// | Active Directory | //
// -------------------- //
// In device mode AD never gets the password: the reveal code when           //
// ADRevealCode is on, otherwise only the expiration time.                   //
    /// Set when this run already issued the code for its new password (ADRevealCode),
    /// so afterRotation doesn't burn it right after it was written to AD.
    private static var issuedForRotation = false

    /// The value for AD's password attribute, and the account label for Windows LAPS JSON.
    /// `newPassword`: AD is being written for a password that just changed, so the old
    /// code is burned now and its replacement is what AD gets.
    static func directorySecret(password: String, newPassword: Bool = false) -> (value: String, account: String)? {
        guard deviceMode else { return (password, Constants.local_admin) }
        guard writesCodeToAD else { return nil }
        let code: String?
        if newPassword && !issuedForRotation {
            code = replaceCode(reason: "new password")
            issuedForRotation = code != nil
        } else {
            code = currentCode()
        }
        guard let value = code else { return nil }
        return (value, "\(Constants.local_admin) (reveal code)")
    }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------------------- //
// | Is anyone holding a code? | //
// ----------------------------- //
// Device mode with nobody collecting the code (no -escrow in 14 days, and   //
// not in AD) means no one can reveal the password.                          //
    static var codeCollected : Bool {
        if writesCodeToAD { return true }
        guard let last = RunState.value("lastEscrow").flatMap(RunState.iso.date(from:)) else { return false }
        return Date().timeIntervalSince(last) < Staging.autoWindow
    }

    static func warnIfNobodyHoldsCode() {
        guard deviceMode, !codeCollected else { return }
        laps_log.print("RetrievalMode is device, but no MDM has collected the reveal code with -escrow in the last 14 days (and ADRevealCode is off): nobody can reveal the password.", .warn)
    }
}

/*
===============================================================================
 macOSLAPS | Command | main.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2017-06-13
 Updated:   2026-11-22

 Purpose:
     The macOSLAPS command. Reads the arguments, moves a password stored
     by an earlier macOSLAPS to the 4.0 keychain item, and rotates the
     local admin's password when it is due, with the Active Directory
     method (like Windows LAPS) or the Local method (keychain only,
     escrowed by your MDM).

 Usage:
     macOSLAPS -help lists every argument.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-22   joshua    -read and -newPassword run only in
                        claude    plaintext escrow, when the MDM's profile
                                  sets AllowRead / AllowNewPassword (exit 78
                                  otherwise); -getPassword too, with
                                  AllowRead.
 4.0.0     2026-11-17   joshua    One path for the AD and Local methods;
                        claude    -getPassword and -firstPass parsing
                                  shortened; -rotateNow handled once;
                                  KeychainItem.
                                  -read for scripts on the Mac (never counts
                                  as a collection); -rotate and
                                  -currentPassword (new names for
                                  -resetPassword and -firstPass); -newPassword
                                  from a prompt or stdin; the staging message
                                  mentions the hook only when it can confirm.
 4.0.0     2026-11-12   joshua    App bundle and new identity
                        claude    (com.joshua-d-miller.macoslaps) with
                                  migration from 3.x / 845; -status, -escrow,
                                  -initialize, -uninstall; staged rotation
                                  (-firstPass never stages); run lock; build
                                  number in -version; deprecation notice for
                                  /usr/local/laps; admin group check on every
                                  rotation run; -reveal, -expireIn and the end
                                  of a grace period; -service, -rotateNow,
                                  -agent and the app window when opened from
                                  Finder; a rotation run stops after an outside
                                  password change and checks
                                  AllowMDMManagedAccount; -reveal codes and
                                  -firstPass - come from a prompt or standard
                                  input, never the command line.

                                  New header and section style.
===============================================================================
*/

import Foundation
import OpenDirectory

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------------------- //
// | Settings and run flags | //
// -------------------------- //
// The settings macOSLAPS runs with, read once from the preferences, and the //
// flags the command-line arguments set.                                     //
struct Constants {
    // Begin by tying date_formatter() to a variable
    static let dateFormatter = date_formatter()
    // Read Command Line Arugments into array to use later
    static let arguments : Array = CommandLine.arguments.map(canonicalArgument)
    // Retrieve our configuration for the application or use the
    // default values
    static let local_admin = GetPreference(preference_key: "LocalAdminAccount") as! String
    static let password_length = GetPreference(preference_key: "PasswordLength") as! Int
    static let days_till_expiration = GetPreference(preference_key: "DaysTillExpiration") as! Int
    static let remove_keychain = GetPreference(preference_key: "RemoveKeychain") as! Bool
    static let characters_to_remove = GetPreference(preference_key: "RemovePassChars") as! String
    static let character_exclusion_sets = GetPreference(preference_key: "ExclusionSets") as? Array<String>
    static let preferred_domain_controller = GetPreference(preference_key: "PreferredDC") as! String
    static var first_password = GetPreference(preference_key: "FirstPass") as! String
    static let method = GetPreference(preference_key: "Method") as! String
    static let passwordrequirements = GetPreference(preference_key: "PasswordRequirements") as! Dictionary<String, Int>
    // Constant values if triggering a password reset / specifying a First Password
    static var pw_reset : Bool = false
    static var use_firstpass : Bool = false
    /// -newPassword: the password to set instead of a generated one.
    static var new_password : String? = nil
    static var initialize : Bool = false
    static var inside_hook : Bool = false
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------- //
// | Arguments and version | //
// ------------------------- //
// Every flag macOSLAPS understands, and the version with its build number.  //
// Every flag macOSLAPS understands (lowercased). Used so -firstPass never takes a flag as its value.
let knownArguments : Set<String> = ["-version", "-getpassword", "-resetpassword", "-help", "-firstpass", "-showconfig", "-status", "-v", "-escrow", "-read", "-newpassword", "-initialize", "-uninstall", "-purge", "-reveal", "-expirein", "-reason", "-service", "-rotatenow", "-agent"]
/// Newer names for older flags (both keep working): -rotate is -resetPassword, and
/// -currentPassword is -firstPass (the account's password right now).
let argumentAliases : [String: String] = ["-rotate": "-resetpassword", "-currentpassword": "-firstpass"]
/// A flag lowercased, with an alias replaced by the flag it stands for.
func canonicalArgument(_ raw: String) -> String {
    let lower = raw.lowercased()
    return argumentAliases[lower] ?? lower
}
/// The argument right after `flag` in its original case, unless it is another flag.
func argumentValue(after flag: String) -> String? {
    let raw = CommandLine.arguments
    guard let i = raw.firstIndex(where: { canonicalArgument($0) == flag }), i + 1 < raw.count,
          !knownArguments.contains(canonicalArgument(raw[i + 1])) else { return nil }
    return raw[i + 1]
}
/// A secret (a reveal code, a FirstPass) read without ever being on the command line,
/// where any process could see it: a prompt that doesn't echo when run in Terminal,
/// otherwise one line from standard input (printf '%s\n' "$code" | macOSLAPS -reveal).
enum SecretInput {
    static func read(prompt: String) -> String? {
        if isatty(STDIN_FILENO) != 0 {
            var buffer = [CChar](repeating: 0, count: 1024)
            defer { for i in buffer.indices { buffer[i] = 0 } }
            guard readpassphrase(prompt, &buffer, buffer.count, Int32(RPP_REQUIRE_TTY)) != nil else { return nil }
            let value = String(cString: buffer)
            return value.isEmpty ? nil : value
        }
        guard var line = readLine(strippingNewline: true) else { return nil }
        if line.hasSuffix("\r") { line.removeLast() }
        return line.isEmpty ? nil : line
    }

    /// The reveal code for -reveal: never from the command line.
    static func revealCode() -> String {
        if let given = argumentValue(after: "-reveal"), given != "-" {
            laps_log.print("Don't put the reveal code on the command line, where other processes can see it. Run macOSLAPS -reveal and type it, or pipe it: printf '%s\\n' \"$code\" | macOSLAPS -reveal", .error)
            exit(64)
        }
        guard let code = read(prompt: "Reveal code: ") else {
            laps_log.print("-reveal needs the reveal code: type it at the prompt, or pipe it: printf '%s\\n' \"$code\" | macOSLAPS -reveal", .error)
            exit(64)
        }
        return code
    }
}

/// Version with build number, e.g. 4.0.0.868, so testers can tell builds apart
/// and version comparisons (sort -V, is-at-least) order builds correctly.
func fullVersion() -> String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return short }
    return "\(short).\(build)"
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------- //
// | Root and the run lock | //
// ------------------------- //
// Rotation needs root, and only one rotation may run at a time.             //
func verify_root() {
    guard NSUserName() != "root" else { return }
    laps_log.print("macOSLAPS needs to be run as root to ensure the password change for \(Constants.local_admin) if needed.", .error)
    exit(77)
}
/// Only one macOSLAPS run may rotate at a time. The LaunchDaemon, an MDM script and an
/// installer's kickstart can all start a run within the same second; without this, two
/// rotations could interleave and leave the keychain and the account disagreeing.
/// The lock is released when the process exits, or earlier with release() (before the
/// inventory hook runs, so a slow hook doesn't hold up other runs). O_CLOEXEC keeps
/// child processes (the hook, system tools) from inheriting it.
enum RunLock {
    private static var descriptor : Int32 = -1
    static func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
    /// Like acquire, but returns false instead of exiting (for the long-running service).
    static func tryAcquire(wait: TimeInterval) -> Bool {
        if descriptor < 0 { descriptor = open("/var/run/macOSLAPS.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { return true }
        let deadline = Date().addingTimeInterval(wait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }
    static func acquire(wait: TimeInterval = 120) {
        descriptor = open("/var/run/macOSLAPS.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }   // no lock file: behave as before
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
        laps_log.print("Another macOSLAPS run is in progress. Waiting for it to finish...", .info)
        let deadline = Date().addingTimeInterval(wait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if Date() > deadline {
                laps_log.print("Another macOSLAPS run is still in progress after \(Int(wait)) seconds. Nothing was changed by this run.", .error)
                exit(1)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------- //
// | -uninstall | //
// -------------- //
// Runs the uninstall script inside the app bundle.                          //
/// -uninstall [-purge]: runs Contents/Resources/uninstall.sh from the app bundle.
func uninstall(purge: Bool) -> Never {
    guard let script = AppBundle.executable("Resources/uninstall.sh") else {
        laps_log.print("uninstall.sh was not found in the macOSLAPS app bundle.", .error)
        exit(1)
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [script] + (purge ? ["--purge"] : [])
    do { try task.run() } catch {
        laps_log.print("Unable to run \(script): \(error.localizedDescription)", .error)
        exit(1)
    }
    task.waitUntilExit()
    exit(task.terminationStatus)
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------- //
// | -initialize | //
// --------------- //
// Adopts the current password without rotating it (#88).                    //
/// -initialize (#88): adopt the current password without rotating it.
func initializeWithoutRotating() -> Never {
    guard !Constants.first_password.isEmpty else {
        laps_log.print("-initialize needs the current password: use -firstPass <password> or set the FirstPass key.", .error)
        exit(1)
    }
    let record = LocalTools.connect()
    // Already managed? Then leave everything alone: re-saving would reset the creation date
    // and postpone rotation forever when an MDM runs -initialize on every check-in, and
    // checking an outdated FirstPass would add a failed login each time.
    if let stored = KeychainService.current, RunState.storedPasswordWorks(stored.password, created: stored.created, record: record) {
        let due = Constants.dateFormatter.string(from: LocalTools.get_expiration_date())
        let what = stored.password == Constants.first_password ? "already initialized with this password" : "already managed by macOSLAPS (the password has been rotated since)"
        laps_log.print("\(Constants.local_admin) is \(what). Nothing was changed; the next rotation is due \(due).", .info)
        RunState.record("initialized", message: "already initialized")
        exit(0)
    }
    guard (try? record.verifyPassword(Constants.first_password)) != nil else {
        laps_log.print("The FirstPass value is not the current password for \(Constants.local_admin). Nothing was stored.", .error)
        exit(1)
    }
    let status = KeychainService.savePassword(service: KeychainNames.current, account: Constants.local_admin, data: Constants.first_password)
    guard status == noErr else {
        laps_log.print("Unable to store the password in the keychain (OSStatus \(status)).", .error)
        exit(1)
    }
    if Constants.method == "AD" {
        let computer = ADTools.connect()
        guard ADTools.set_password(computer_record: computer, password: Constants.first_password, new_ad_exp_date: TimeConversion.windows()) == 0 else {
            laps_log.print("Stored locally, but Active Directory could not be updated. The next run will rotate as usual.", .warn)
            exit(1)
        }
    }
    let expires = Constants.dateFormatter.string(from: LocalTools.get_expiration_date())
    RunState.record("initialized")
    RunState.noteVerified(true, created: KeychainService.current?.created)
    laps_log.print("Initialized \(Constants.local_admin) with its current password. No rotation was performed; the first rotation is due \(expires).", .info)
    if !(GetPreference(preference_key: "FirstPass") as? String ?? "").isEmpty {
        laps_log.print("FirstPass is set in the configuration, which any user of this Mac can read, and it is still \(Constants.local_admin)'s password until the first rotation. Remove FirstPass from the profile, or rotate soon with macOSLAPS -resetPassword.", .warn)
    }
    InventoryHook.run(reason: "initialize")
    exit(0)
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------------------- //
// | -read and -newPassword | //
// -------------------------- //
// The password for scripts on this Mac, and a password chosen by a person.  //
/// -read, -getPassword and -newPassword are the 3.x-style plaintext path:
/// root on this Mac reads the password, or chooses one. They exist only in
/// plaintext escrow, and only when the MDM's profile sets the Allow key (the
/// admin's acknowledgement). With EscrowCertificates or in device mode the
/// password is never handed out in plaintext, whatever the key says. Exit 78.
func requireAllowed(_ key: String, for command: String, because reason: String) {
    if Reveal.deviceMode {
        laps_log.print("\(command) isn't available in device mode: the password is only shown at the Mac with a reveal code (macOSLAPS -reveal, or the app).", .error)
        exit(78)
    }
    if Escrow.certificateConfig().configured {
        laps_log.print("\(command) isn't available with EscrowCertificates set: the password only leaves macOSLAPS encrypted. Use -escrow and decrypt it with your private key.", .error)
        exit(78)
    }
    guard (GetPreference(preference_key: key) as? Bool) == true else {
        laps_log.print("\(command) is turned off: it \(reason). To allow it, set \(key) to true in your macOSLAPS configuration profile (a value in /Library/Preferences is ignored).", .error)
        exit(78)
    }
}

/// -read: the current password on one line, for scripts on this Mac (XCreds,
/// the macOS installer). Unlike -escrow it never counts as the MDM collecting
/// a staged password. Only in plaintext escrow with AllowRead.
func readForScripts() -> Never {
    if Reveal.deviceMode {
        laps_log.print("RetrievalMode is device: the password is only shown with a reveal code (macOSLAPS -reveal, or the app).", .error)
        exit(1)
    }
    guard let stored = KeychainService.current else {
        laps_log.print("No macOSLAPS password is stored for \(Constants.local_admin) yet. Nothing was printed.", .error)
        exit(1)
    }
    guard RunState.storedPasswordWorks(stored.password, created: stored.created, record: LocalTools.connect()) else {
        laps_log.print("The stored password doesn't work for \(Constants.local_admin) right now. Nothing was printed; see macOSLAPS -status -v.", .error)
        exit(1)
    }
    print(stored.password)
    exit(0)
}

/// -newPassword: the password to set instead of a generated one, typed at a prompt or
/// piped in (never on the command line), checked against the password settings.
func chosenPassword() -> String {
    if let given = argumentValue(after: "-newpassword"), given != "-" {
        laps_log.print("Don't put the new password on the command line, where other processes can see it. Type it at the prompt, or pipe it: printf '%s\\n' \"$password\" | macOSLAPS -rotate -newPassword -", .error)
        exit(64)
    }
    guard let chosen = SecretInput.read(prompt: "New password for \(Constants.local_admin): ") else {
        laps_log.print("-newPassword needs the new password: type it at the prompt, or pipe it: printf '%s\\n' \"$password\" | macOSLAPS -rotate -newPassword -", .error)
        exit(64)
    }
    do {
        try PasswordGenerator.checkChosen(chosen, policy: currentPasswordPolicy(length: Constants.password_length))
    } catch {
        laps_log.print("\(error) Nothing was changed.", .error)
        exit(1)
    }
    laps_log.print("Using the password given with -newPassword for \(Constants.local_admin) instead of a generated one. A password a person chose is easier to guess; the next rotation generates one again.", .warn)
    return chosen
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------------- //
// | Rotating or staging | //
// ----------------------- //
// Finishes an interrupted rotation, applies a staged password once the MDM  //
// has it, or stages or rotates a new one when it is due.                    //
/// Decides what this run does about the password, with staged rotation:
///  - finish an apply that was interrupted (power loss / SIGKILL) if the account already
///    uses the pending password,
///  - apply a pending password once the MDM has it (or when staging is off),
///  - otherwise stage a new password when one is due, or wait.
/// `apply(nil)` rotates to a newly generated password; `apply(p)` to the pending one.
/// Returns only when nothing needed doing (not due, no pending); otherwise exits.
func rotateOrStage(due: Bool, finishInterrupted: (String) -> Void, apply: (String?) -> Void) {
    if Staging.interruptedApply, let pending = Staging.pending() {
        let record = LocalTools.connect()
        if (try? record.verifyPassword(pending.password)) != nil {
            laps_log.print("Finishing a rotation that was interrupted after the account was changed.", .warn)
            let status = KeychainService.savePassword(service: KeychainNames.current, account: Constants.local_admin, data: pending.password)
            guard status == noErr else {
                laps_log.print("Unable to store the password while finishing the interrupted rotation (OSStatus \(status)).", .error)
                exit(1)
            }
            finishInterrupted(pending.password)
            Staging.finishApply()
            RunState.record("rotated", message: "finished an interrupted rotation")
            RunState.noteVerified(true, created: KeychainService.current?.created)
            InventoryHook.run(reason: "finishing an interrupted rotation")
            exit(0)
        }
        // The account was never changed: the pending password is still just pending.
        RunState.set([:], remove: ["applying"])
    }

    // -newPassword replaces a staged password instead of applying it.
    if Constants.new_password == nil, let pending = Staging.pending() {
        if !Staging.active {
            laps_log.print("Staged rotation is off; applying the pending password now.", .info)
            apply(pending.password); exit(0)
        }
        if !Staging.confirmed && Constants.pw_reset {
            Staging.runHookAndCheck()
            RunLock.acquire()
        }
        if Staging.confirmed {
            laps_log.print("The pending password has been collected by the MDM (\(Staging.exports) export(s)). Applying it.", .info)
            apply(pending.password); exit(0)
        }
        laps_log.print("A new password is staged and waiting for the MDM to collect it (\(Staging.exports) of \(Staging.confirmationsNeeded) -escrow export(s)). The current password stays in use until then.", .info)
        RunState.record("staged", message: "waiting for \(Staging.confirmationsNeeded - Staging.exports) more -escrow export(s)")
        exit(0)
    }

    guard due else { return }
    guard Staging.active else { apply(nil); exit(0) }
    // Taking over an account (-firstPass) or having no stored password: there is no
    // escrowed password to protect yet, and a FirstPass given on the command line would
    // be gone by the time a staged password is applied. Rotate now.
    if Constants.use_firstpass || KeychainService.current == nil {
        laps_log.print("No managed password yet (or -firstPass): rotating now instead of staging.", .info)
        apply(nil); exit(0)
    }

    let next = PasswordGen(length: Constants.password_length)
    guard Staging.stage(next) else { exit(1) }
    let sooner = InventoryHook.confirmsExports ? ", or sooner through the InventoryHook" : ""
    laps_log.print("Staged a new password for \(Constants.local_admin). It will be applied on the first macOSLAPS run after the MDM collects it with -escrow (\(Staging.confirmationsNeeded) export(s)\(sooner)).", .info)
    Staging.runHookAndCheck()
    if Staging.confirmed {
        RunLock.acquire()
        apply(next); exit(0)
    }
    RunState.record("staged", message: "waiting for \(Staging.confirmationsNeeded) -escrow export(s)")
    exit(0)
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------- //
// | Main | //
// -------- //
// Handles each argument, then rotates with the AD or Local method when the  //
// password is due.                                                          //
func macOSLAPS() {
    laps_log_shell_timeout = { path, timeout in
        laps_log.print("\(path) did not finish within \(Int(timeout)) seconds and was stopped.", .warn)
    }
    // -version and -help must print exactly their own output and touch nothing else:
    // MDM scripts parse `macOSLAPS -version`.
    if Constants.arguments.contains("-version") {
        print(fullVersion())
        exit(0)
    }
    // The app: the menu bar agent (LaunchAgent), or the window when opened from Finder.
    if Constants.arguments.contains("-agent") { Agent.run() }
    if AppUI.openedAsApp { AppUI.run(WindowDelegate(), accessory: false) }
    // Commands whose stdout is read by scripts or people must not have log lines mixed in.
    if !Constants.arguments.filter({ ["-status", "-escrow", "-read", "-showconfig", "-help", "-reveal", "-service", "-rotatenow"].contains($0) }).isEmpty {
        laps_log.useStandardError = true
    }
    // An inventory hook (e.g. jamf recon) can run scripts that call macOSLAPS again. Those
    // nested runs may read (-escrow, -getPassword, -status) but must not rotate or re-run the hook.
    Constants.inside_hook = ProcessInfo.processInfo.environment[InventoryHook.environmentMarker] == "1"
    // Move the password stored by 3.x / 845 to the new keychain item before anything
    // reads it (and before the old -getPassword export below is deleted: it is one of
    // the migration sources). -firstPass and -initialize are how a Mac recovers when
    // migration is required, and -status reports it, so those runs continue.
    let args = Set(Constants.arguments)
    if args.contains("-uninstall") {
        verify_root()
        uninstall(purge: args.contains("-purge"))
    }
    // The privileged service (second LaunchDaemon) and the commands a standard user may run
    // through it. The check LaunchDaemon handles migration, so the service skips it.
    if args.contains("-service") {
        verify_root()
        Service.run()
    }
    if NSUserName() != "root" {
        if args.contains("-reveal") {
            Service.clientReveal(code: SecretInput.revealCode(), reason: argumentValue(after: "-reason") ?? "")
        }
        if args.contains("-status") && !args.contains("-v") { Service.clientStatus() }
    }
    // Root ends the grace period directly; anyone else asks the service.
    if args.contains("-rotatenow") { Service.rotateNow() }
    if NSUserName() == "root" && args.isDisjoint(with: ["-showconfig", "-help"]) {
        let reporting = args.contains("-status")
        let recovering = args.contains("-firstpass") || args.contains("-initialize")
        let rotationRun = args.isDisjoint(with: ["-status", "-escrow", "-read", "-getpassword"]) && !Constants.inside_hook
        Migration.run(fatal: !(reporting || recovering), rotationRun: rotationRun)
    }
    // Delete the temporary -getPassword export from a previous run
    if NSUserName() == "root",
       let exp_keychain_id = try? String(contentsOfFile: "/var/root/.GeneratedLAPSServiceName", encoding: .utf8),
       Constants.method == "Local" {
        _ = KeychainService.deleteExport(service: exp_keychain_id.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // Iterate through supported Arguments
    for argument in Constants.arguments {
        switch argument {
        case "-getpassword":
            // Deprecated, removed in 5.0: copies the password to a temporary System
            // keychain item that /usr/bin/security can read, deleted on the next run.
            verify_root()
            requireAllowed("AllowRead", for: "-getPassword", because: "copies the password in plaintext to a keychain item")
            guard Constants.method == "Local" else {
                laps_log.print("Password WILL NOT be exported as the current method is set to Active Directory", .warn)
                exit(0)
            }
            guard let stored = KeychainService.current else {
                laps_log.print("There does not appear to be a macOSLAPS Keychain Entry. Most likely, a password change has never been performed or the first password change has failed due to an incorrect password", .error)
                exit(1)
            }
            guard RunState.storedPasswordWorks(stored.password, created: stored.created, record: LocalTools.connect()) else {
                laps_log.print("Password verification failed. Please use sysadminctl to reset. Exiting...")
                exit(1)
            }
            laps_log.print("Password has been verified to work. Extracting...", .info)
            let expiration = Constants.dateFormatter.string(from: LocalTools.get_expiration_date())
            let random_service_name = UUID().uuidString
            guard KeychainService.exportPassword(service: random_service_name, account: "root \(random_service_name)", data: stored.password, expiration: expiration) == noErr else {
                laps_log.print("Unable to extract password to another keychain entry accessible by the security executable. Exiting...")
                exit(1)
            }
            laps_log.print("Password was extracted to keychain item. This WILL BE deleted on next run.", .info)
            try? random_service_name.write(toFile: "/var/root/.GeneratedLAPSServiceName", atomically: true, encoding: String.Encoding.utf8)
            exit(0)
        case "-resetpassword":
            Constants.pw_reset = true
        case "-showconfig":
            printEffectiveConfiguration()
            exit(0)
        case "-status":
            verify_root()
            Status.run(verbose: Constants.arguments.contains("-v"))
        case "-escrow":
            verify_root()
            Escrow.run()
        case "-read":
            verify_root()
            requireAllowed("AllowRead", for: "-read", because: "prints the password in plaintext on this Mac")
            readForScripts()
        case "-newpassword":
            requireAllowed("AllowNewPassword", for: "-newPassword", because: "sets a password a person chose")
            Constants.pw_reset = true
            Constants.new_password = chosenPassword()
        case "-reveal":
            verify_root()
            Reveal.runCommand(code: SecretInput.revealCode())
        case "-expirein":
            verify_root()
            guard let time = argumentValue(after: "-expirein") else {
                laps_log.print("-expireIn needs a time: macOSLAPS -expireIn 4h", .error)
                exit(64)
            }
            Reveal.expireIn(time)
        case "-initialize":
            Constants.initialize = true
            
        case "-help":
            print("""
                  macOSLAPS Help
                  ==============
                  
                  These are the arguments that you can use with macOSLAPS.
                  
                  -version          Prints Current Version of macOSLAPS and gracefully exits
                  
                  -getpassword      Deprecated (use -escrow). Local method only: copies the
                                    password to a temporary System keychain item that
                                    /usr/bin/security can read, and writes that item's name
                                    to /var/root/.GeneratedLAPSServiceName. The copy is
                                    deleted on the next run.
                  
                  -rotate           Changes the password now, whatever the expiration
                                    date (also -resetPassword).
                  -currentPassword  With -rotate: the account's password right now,
                                    when macOSLAPS doesn't have it (also -firstPass).
                                    Without a value, the FirstPass key is used. Use
                                    -currentPassword - to type it at a prompt or pipe
                                    it in, so it never shows in the process list:
                                    printf '%s\\n' "$pw" | macOSLAPS -rotate -currentPassword -
                  -newPassword -    With -rotate: set this password instead of a
                                    generated one. Typed at a prompt or piped in, never
                                    on the command line; it must meet the password
                                    settings. With -currentPassword - as well, give
                                    the passwords on separate lines, in the order of
                                    the options. Plaintext escrow only, and only
                                    when your MDM's profile sets AllowNewPassword.
                  
                  -status           One line of JSON describing the account, secureToken,
                                    FileVault, stored password and escrow settings, for an
                                    MDM inventory attribute. Add -v for a readable checklist.

                  -escrow           Prints the current password for an MDM inventory
                                    attribute: JSON, or a CMS (PKCS #7) block encrypted to
                                    the EscrowCertificates when configured.

                  -read             Prints the current password, alone on one line, for
                                    scripts on this Mac. Never counts as the MDM
                                    collecting a staged password (-escrow does). The
                                    3.x-style path: plaintext escrow only, and only
                                    when your MDM's profile sets AllowRead.

                  -initialize       With -firstPass <password> (or the FirstPass key):
                                    verify that password and store it WITHOUT rotating.
                                    The first rotation then happens after
                                    DaysTillExpiration (#88).

                  -reveal           RetrievalMode device: asks for the reveal code
                                    (escrowed with -escrow), shows the password and
                                    starts the RevealGracePeriod countdown. Type the
                                    code at the prompt or pipe it in; it is never
                                    accepted on the command line:
                                    printf '%s\\n' "$code" | macOSLAPS -reveal
                                    Works without root through the macOSLAPS service.
                                    Add -reason "<ticket>" to record why.

                  -rotateNow        Ends an active reveal or -expireIn grace period
                                    now (any user; the menu bar uses this).

                  -expireIn <time>  The password changes after <time> (4h, 30m,
                                    2h30m, 0 = next run), e.g. after a technician
                                    used it.

                  -uninstall        Removes macOSLAPS (app, LaunchDaemon, symlink,
                                    receipts). The stored password is kept so a
                                    reinstall continues; add -purge to delete it and
                                    the state too (make sure your MDM has it first).

                  -showconfig       Prints the settings macOSLAPS will use, which
                                    preference domain they came from, and whether
                                    each key is managed, set, or a default.
                                    FirstPass is never printed.
                  
                  -help             Displays this screen
                  """)
            exit(0)
        case "-firstpass":
            Constants.pw_reset = true
            Constants.use_firstpass = true
            // The value is the argument right after -firstPass, in its original case and in
            // any position (#92). A value on the command line overrides the FirstPass key.
            if let given = argumentValue(after: "-firstpass") {
                if given == "-" {
                    // -firstPass -: typed at a prompt or piped in, never on the command line.
                    guard let typed = SecretInput.read(prompt: "Current password for \(Constants.local_admin): ") else {
                        laps_log.print("-firstPass - needs the current password on standard input.", .error)
                        exit(1)
                    }
                    Constants.first_password = typed
                    laps_log.print("The -firstPass argument was invoked. Using the password given on standard input.", .info)
                } else {
                    Constants.first_password = given
                    laps_log.print("The -firstPass argument was invoked. Using the password given on the command line, which other processes can see while macOSLAPS runs. Pipe it instead: printf '%s\\n' \"$password\" | macOSLAPS -firstPass - -resetPassword", .warn)
                }
            } else {
                laps_log.print("The -firstPass argument was invoked. Using the FirstPass value from the configuration.", .info)
            }
            if Constants.first_password == "" {
                laps_log.print("No password is specified via the FirstPass key OR in the command line. Exiting...", .error)
                exit(1)
            }
        default:
            continue
        }
    }
    if Constants.inside_hook {
        laps_log.print("Running inside the inventory hook: no rotation is performed in this run.", .info)
        exit(0)
    }
    verify_root()
    if AppBundle.startedFromLegacyPath {
        laps_log.print("\(AppBundle.legacyPath) is deprecated and is removed in macOSLAPS 5.0. Use \(AppBundle.installedExecutable) (the LaunchDaemon already does).", .warn)
    }
    RunLock.acquire()
    RunState.begin()
    Ownership.exitIfStopped()
    MDMAccounts.checkManagedAccount()
    AdminGroup.check()
    // A reveal or -expireIn deadline that has passed forces this run to rotate.
    Reveal.endOfGraceIfDue()
    if Reveal.deviceMode {
        _ = Reveal.currentCode()
        Reveal.warnIfNobodyHoldsCode()
    }
    if Constants.initialize {
        initializeWithoutRotating()
    }
    // When the password expires, and how a rotation is done, for the AD or Local method.
    let expires : Date
    let finishInterrupted : (String) -> Void
    let apply : (String?) -> Void
    switch Constants.method {
    case "AD":
        let computer = ADTools.connect()
        let attribute = Constants.pw_reset ? TimeConversion.expired : ADTools.check_pw_expiration(computer_record: computer)
        expires = TimeConversion.epoch(exp_time: attribute) ?? .distantPast
        finishInterrupted = { ADTools.restoreAfterInterruptedApply(computer_record: computer, password: $0) }
        apply = { staged in
            // Make sure the domain controller we're connected to is writable first.
            ADTools.verify_dc_writability(computer_record: computer)
            PreferenceStore.shared.emitNotices()
            laps_log.print("Password Change is required as the LAPS password for \(Constants.local_admin), has expired", .info)
            ADTools.password_change(computer_record: computer, staged: staged)
        }
    case "Local":
        // The keychain holds the password; an MDM (or another report) escrows it.
        expires = Constants.pw_reset ? .distantPast : LocalTools.get_expiration_date()
        finishInterrupted = { _ in }
        apply = { staged in
            PreferenceStore.shared.emitNotices()
            LocalTools.password_change(staged: staged)
            laps_log.print("Password change has been completed for the local admin \(Constants.local_admin). New expiration date is \(Constants.dateFormatter.string(from: LocalTools.get_expiration_date()))", .info)
        }
    default:
        laps_log.print("Unknown Method \"\(Constants.method)\". Set Method to AD or Local in \(PreferenceStore.shared.domain).", .error)
        exit(1)
    }
    // Exits whenever it rotated, staged or applied; returns only when nothing is due.
    rotateOrStage(due: expires < Date(), finishInterrupted: finishInterrupted, apply: apply)
    laps_log.print("Password change is not required as the password for \(Constants.local_admin) does not expire until \(Constants.dateFormatter.string(from: expires))", .info)
    RunState.record("not-due")
    Reveal.waitForDeadlineIfSoon()
    exit(0)
}

macOSLAPS()

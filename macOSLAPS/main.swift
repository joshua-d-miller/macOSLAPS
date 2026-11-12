/*
===============================================================================
 macOSLAPS | Command | main.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2017-06-13
 Updated:   2026-11-12

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
                                  AllowMDMManagedAccount.

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
    static let arguments : Array = CommandLine.arguments.map {$0.lowercased()}
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
    static var initialize : Bool = false
    static var inside_hook : Bool = false
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------- //
// | Arguments and version | //
// ------------------------- //
// Every flag macOSLAPS understands, and the version with its build number.  //
// Every flag macOSLAPS understands (lowercased). Used so -firstPass never takes a flag as its value.
let knownArguments : Set<String> = ["-version", "-getpassword", "-resetpassword", "-help", "-firstpass", "-showconfig", "-status", "-v", "-escrow", "-initialize", "-uninstall", "-purge", "-reveal", "-expirein", "-reason", "-service", "-rotatenow", "-agent"]
/// The argument right after `flag` in its original case, unless it is another flag.
func argumentValue(after flag: String) -> String? {
    let raw = CommandLine.arguments
    guard let i = raw.firstIndex(where: { $0.lowercased() == flag }), i + 1 < raw.count,
          !knownArguments.contains(raw[i + 1].lowercased()) else { return nil }
    return raw[i + 1]
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
    // Check if running as root
    let current_running_User = NSUserName()
    if current_running_User != "root" {
        laps_log.print("macOSLAPS needs to be run as root to ensure the password change for \(Constants.local_admin) if needed.", .error)
        exit(77)
    } else {
        return
    }
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
    let (stored, created) = KeychainService.loadPassword(service: KeychainNames.current)
    if let current = stored, RunState.storedPasswordWorks(current, created: created, record: record) {
        let due = LocalTools.get_expiration_date().map { Constants.dateFormatter.string(from: $0) } ?? "unknown"
        let what = current == Constants.first_password ? "already initialized with this password" : "already managed by macOSLAPS (the password has been rotated since)"
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
        let expiration = TimeConversion.windows()!
        guard ADTools.set_password(computer_record: computer, password: Constants.first_password, new_ad_exp_date: expiration) == 0 else {
            laps_log.print("Stored locally, but Active Directory could not be updated. The next run will rotate as usual.", .warn)
            exit(1)
        }
    }
    let expires = LocalTools.get_expiration_date().map { Constants.dateFormatter.string(from: $0) } ?? "unknown"
    RunState.record("initialized")
    RunState.noteVerified(true, created: KeychainService.loadPassword(service: KeychainNames.current).1)
    laps_log.print("Initialized \(Constants.local_admin) with its current password. No rotation was performed; the first rotation is due \(expires).", .info)
    if !(GetPreference(preference_key: "FirstPass") as? String ?? "").isEmpty {
        laps_log.print("FirstPass is set in the configuration, which any user of this Mac can read, and it is still \(Constants.local_admin)'s password until the first rotation. Remove FirstPass from the profile, or rotate soon with macOSLAPS -resetPassword.", .warn)
    }
    InventoryHook.run(reason: "initialize")
    exit(0)
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
            RunState.noteVerified(true, created: KeychainService.loadPassword(service: KeychainNames.current).1)
            InventoryHook.run(reason: "finishing an interrupted rotation")
            exit(0)
        }
        // The account was never changed: the pending password is still just pending.
        RunState.set([:], remove: ["applying"])
    }

    if let pending = Staging.pending() {
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
    if Constants.use_firstpass || KeychainService.loadPassword(service: KeychainNames.current).0 == nil {
        laps_log.print("No managed password yet (or -firstPass): rotating now instead of staging.", .info)
        apply(nil); exit(0)
    }

    let next = PasswordGen(length: Constants.password_length)
    guard Staging.stage(next) else { exit(1) }
    laps_log.print("Staged a new password for \(Constants.local_admin). It will be applied after the MDM collects it with -escrow (\(Staging.confirmationsNeeded) export(s), or sooner through the InventoryHook).", .info)
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
    if !Constants.arguments.filter({ ["-status", "-escrow", "-showconfig", "-help", "-reveal", "-service", "-rotatenow"].contains($0) }).isEmpty {
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
        if args.contains("-reveal"), let code = argumentValue(after: "-reveal") {
            Service.clientReveal(code: code, reason: argumentValue(after: "-reason") ?? "")
        }
        if args.contains("-status") && !args.contains("-v") { Service.clientStatus() }
        if args.contains("-rotatenow") { Service.rotateNow() }
    }
    if args.contains("-rotatenow") { Service.rotateNow() }
    if NSUserName() == "root" && args.isDisjoint(with: ["-showconfig", "-help"]) {
        let reporting = args.contains("-status")
        let recovering = args.contains("-firstpass") || args.contains("-initialize")
        let rotationRun = args.isDisjoint(with: ["-status", "-escrow", "-getpassword"]) && !Constants.inside_hook
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
            verify_root()
            if Reveal.deviceMode {
                laps_log.print("RetrievalMode is device: the password is only shown with a reveal code (macOSLAPS -reveal <code>, or the app).", .error)
                exit(1)
            }
            if Constants.method == "Local" {
                let (current_password, keychain_item_check) = KeychainService.loadPassword(service: KeychainNames.current)
                if current_password == nil && keychain_item_check == nil {
                    laps_log.print("Unable to retrieve password from macOSLAPS Keychain entry.", .error)
                    exit(1)
                } else if current_password == nil && keychain_item_check == "Not Found" {
                    laps_log.print("There does not appear to be a macOSLAPS Keychain Entry. Most likely, a password change has never been performed or the first password change has failed due to an incorrect password", .error)
                    exit(1)
                } else {
                    // Pull Local Administrator Record
                    guard let local_node = try? ODNode.init(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)) else {
                        laps_log.print("Unable to connect to local node.", .error)
                        exit(1)
                    }
                    guard let local_admin_record = try? local_node.record(withRecordType: kODRecordTypeUsers, name: Constants.local_admin, attributes: kODAttributeTypeRecordName) else {
                        laps_log.print("Unable to retrieve local administrator record.", .error)
                        exit(1)
                    }
                    // Verify Password
                    guard RunState.storedPasswordWorks(current_password!, created: keychain_item_check, record: local_admin_record)
                    else {
                        laps_log.print("Password verification failed. Please use sysadminctl to reset. Exiting...")
                        exit(1)
                    }
                    laps_log.print("Password has been verified to work. Extracting...", .info)
                    let current_expiration_date = LocalTools.get_expiration_date()
                    let current_expiration_string = Constants.dateFormatter.string(for: current_expiration_date)!
                    let random_service_name = UUID().uuidString
                    let copy_status : OSStatus = KeychainService.exportPassword(service: random_service_name, account: "root \(random_service_name)", data: current_password!, expiration: current_expiration_string)
                    if copy_status == noErr {
                        laps_log.print("Password was extracted to keychain item. This WILL BE deleted on next run.", .info)
                    } else {
                        laps_log.print("Unable to extract password to another keychain entry accessible by the security executable. Exiting...")
                        exit(1)
                    }
                    try? random_service_name.write(toFile: "/var/root/.GeneratedLAPSServiceName", atomically: true, encoding: String.Encoding.utf8)
                    exit(0)
                }
            } else {
                laps_log.print("Password WILL NOT be exported as the current method is set to Active Directory", .warn)
                exit(0)
            }
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
        case "-reveal":
            verify_root()
            guard let code = argumentValue(after: "-reveal") else {
                laps_log.print("-reveal needs the reveal code: macOSLAPS -reveal <code>", .error)
                exit(64)
            }
            Reveal.runCommand(code: code)
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
                  
                  -resetpassword    Forces a password reset no matter the expiration date
                  -firstpass        Performs a password reset using the FirstPass Configuration
                                    Profile key or the password you specify after this flag.
                                    The password of the admin MUST be this password or the
                                    change WILL FAIL.
                  
                  -status           One line of JSON describing the account, secureToken,
                                    FileVault, stored password and escrow settings, for an
                                    MDM inventory attribute. Add -v for a readable checklist.

                  -escrow           Prints the current password for an MDM inventory
                                    attribute: JSON, or a CMS (PKCS #7) block encrypted to
                                    the EscrowCertificates when configured.

                  -initialize       With -firstPass <password> (or the FirstPass key):
                                    verify that password and store it WITHOUT rotating.
                                    The first rotation then happens after
                                    DaysTillExpiration (#88).

                  -reveal <code>    RetrievalMode device: shows the password for the
                                    reveal code (escrowed with -escrow) and starts
                                    the RevealGracePeriod countdown. Works without
                                    root through the macOSLAPS service. Add
                                    -reason "<ticket>" to record why.

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
            let raw_arguments = CommandLine.arguments
            if let flag_index = raw_arguments.firstIndex(where: { $0.lowercased() == "-firstpass" }),
               flag_index + 1 < raw_arguments.count,
               !knownArguments.contains(raw_arguments[flag_index + 1].lowercased()) {
                Constants.first_password = raw_arguments[flag_index + 1]
                laps_log.print("The -firstPass argument was invoked. Using the password given on the command line.", .info)
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
    switch Constants.method {
    case "AD":
        verify_root()
        // Active Directory Password Change Function
        let ad_computer_record = ADTools.connect()
        // Get Expiration Time from Active Directory
        var ad_exp_time = ""
        if Constants.pw_reset == true {
            ad_exp_time = "126227988000000000"
        } else {
            ad_exp_time = ADTools.check_pw_expiration(computer_record: ad_computer_record)!
        }
        // Convert that time into a date
        let exp_date = TimeConversion.epoch(exp_time: ad_exp_time)
        // Compare that newly calculated date against now to see if a change is required
        rotateOrStage(due: exp_date! < Date(), finishInterrupted: { pending in
            ADTools.restoreAfterInterruptedApply(computer_record: ad_computer_record, password: pending)
        }, apply: { staged in
            // Check if the domain controller that we are connected to is writable
            ADTools.verify_dc_writability(computer_record: ad_computer_record)
            PreferenceStore.shared.emitNotices()
            laps_log.print("Password Change is required as the LAPS password for \(Constants.local_admin), has expired", .info)
            ADTools.password_change(computer_record: ad_computer_record, staged: staged)
        })
        if exp_date! < Date() {
            exit(0)
        }
        else {
            let actual_exp_date = Constants.dateFormatter.string(from: exp_date!)
            laps_log.print("Password change is not required as the password for \(Constants.local_admin) does not expire until \(actual_exp_date)", .info)
            RunState.record("not-due")
            Reveal.waitForDeadlineIfSoon()
            exit(0)
        }
    case "Local":
        verify_root()
        // Local method to perform passwords changes locally vs relying on Active Directory.
        // It is assumed that users will be using either an MDM or some reporting method to store
        // the password somewhere
        // Load the Keychain Item and compare the date
        var exp_date : Date?
        if Constants.pw_reset == true {
            exp_date = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        } else {
            exp_date = LocalTools.get_expiration_date()
        }
        rotateOrStage(due: exp_date! < Date(), finishInterrupted: { _ in }, apply: { staged in
            PreferenceStore.shared.emitNotices()
            LocalTools.password_change(staged: staged)
            let new_exp_date = LocalTools.get_expiration_date()
            laps_log.print("Password change has been completed for the local admin \(Constants.local_admin). New expiration date is \(Constants.dateFormatter.string(from: new_exp_date!))", .info)
        })
        if exp_date! < Date() {
            exit(0)
        }
        else {
            laps_log.print("Password change is not required as the password for \(Constants.local_admin) does not expire until \(Constants.dateFormatter.string(from: exp_date!))", .info)
            RunState.record("not-due")
            Reveal.waitForDeadlineIfSoon()
            exit(0)
        }
    default:
        laps_log.print("Unknown Method \"\(Constants.method)\". Set Method to AD or Local in \(PreferenceStore.shared.domain).", .error)
        exit(1)
    }
}

macOSLAPS()

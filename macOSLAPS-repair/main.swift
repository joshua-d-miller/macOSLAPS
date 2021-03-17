///  -----------------------------
///     Keychain repair for macOSLAPS
///  -----------------------------
///  Command line executable that will open and
///  resave the keychain entry for macOSLAPS so that
///  we can cotinue with password rotation. Specifically
///  used for rotating our bundle identifier and signing certfiicate
///  -------------------------
///  Joshua D. Miller - josh@psu.edu
///  The Pennsylvania State University
///  Last Updated March 17, 2021
///  -------------------------

import Foundation

func macOSLAPSrepair() {
    let process_output = Shell.run(launchPath: "/bin/ps", arguments: ["-e", "-o", "command"])
    let items = process_output.components(separatedBy: "\n")
    var macOSLAPS_running = false
    
    if items.contains("/usr/local/laps/macOSLAPS") {
        macOSLAPS_running = true
    }
    if macOSLAPS_running == true {
        laps_log.print("macOSLAPS is running. Performing keychain repair", .info)
        // Load the password using this tool so we can resave with the new password for
        // bundle and cert rotation
        let (password, create_date) = KeychainService.loadPassword(service: "macOSLAPS")
        if password == nil {
            laps_log.print("Unable to retrieve the password from keychain using the repair utility. You can try running macOSLAPS regulary with a password rotation to ensure that we have access to the keychain entry otherwise please use the sysadminctl command to reset the password for the LAPS account to the FirstPass attribute from the configuration and run macOSLAPS again!", .error)
            exit(1)
        }
        // Save the keychain entry as a new keychain entry
        let save_status = KeychainService.savePassword(service: "macOSLAPS", account: "LAPS Password", data: password!, create_date: create_date!)
        if save_status == noErr {
            laps_log.print("Repair of keychain item for macOSLAPS has been completed", .info)
            exit(0)
        } else {
            laps_log.print("Unable to save keychain entry using the repair tool. This machine will now require a password reset to continue using macOSLAPS. Please use the sysadminctl command to reset the password of your admin using another secureToken user to the first password and then attempt to run macOSLAPS fresh again!", .error)
            exit(1)
        }
    } else {
        laps_log.print("macOSLAPS is NOT running currently. Exiting...", .info)
        exit(0)
    }
}

macOSLAPSrepair()


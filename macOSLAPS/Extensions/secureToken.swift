///
///  secureToken.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 2/21/21.
///  The Pennsylvania State University
///

import Foundation


func Determine_secureToken() -> Bool {
    /* --- Change the password for the account --- */
    // Check OS Version as that will determine how we proceed
    if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion.init(majorVersion: 10, minorVersion: 13, patchVersion: 0)) {
        // Check for secureToken
        let secure_token_status = Shell.run(launchPath: "/usr/sbin/sysadminctl", arguments: ["-secureTokenStatus", Constants.local_admin])
        if secure_token_status.contains("ENABLED") {
            laps_log.print("The local admin: \(Constants.local_admin) has been detected to have a secureToken. Performing secure password change...", .info)
            return(true)
        }
        else {
            return(false)
        }
    }
    else {
        // Determine if FileVault is Enabled
        let fv_status = Shell.run(launchPath: "/usr/bin/fdesetup", arguments: ["status"])
        if (fv_status.contains("FileVault is On.")) {
        // Check if Local Admin is a FileVault User
            let fv_user_cmd = Shell.run(launchPath: "/usr/bin/fdesetup", arguments: ["list"])
            let fv_user_list = fv_user_cmd.components(separatedBy: [",", "\n"])
            // Is Our Admin User a FileVault User?
            if (fv_user_list.contains(Constants.local_admin)) {
                laps_log.print("The local admin: \(Constants.local_admin) is currently a FileVault user. Performing secure password change...", .info)
                return(true)
            }
            else {
                return(false)
            }
        }
        else {
            return(false)
        }
    }
}

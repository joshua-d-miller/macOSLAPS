///  ------------------------
///     LAPS for macOS Devices
///  ------------------------
///  Command line executable that handles automatic
///  generation and rotation of the local administrator
///  password.
///
///  Current Usage:
///    - Active Directory (Similar to Windows functionality)
///    - Local (Password stored in Keychain Only)
///  -------------------------
///  Joshua D. Miller - josh.miller@outlook.com
///  
///  Last Updated March 17, 2021
///  -------------------------

import Foundation

struct Constants {
    // Begin by setting our
    static let dateFormatter = date_formatter()
    // Read Command Line Arugments into array to use later
    static let arguments : Array = CommandLine.arguments
    // Retrieve our configuration for the application or use the
    // default values
    static let local_admin = GetPreference(preference_key: "LocalAdminAccount") as! String
    static let password_length = GetPreference(preference_key: "PasswordLength") as! Int
    static let days_till_expiration = GetPreference(preference_key: "DaysTillExpiration") as! Int
    static let remove_keychain = GetPreference(preference_key: "RemoveKeychain") as! Bool
    static let characters_to_remove = GetPreference(preference_key: "RemovePassChars") as! String
    static let character_exclusion_sets = GetPreference(preference_key: "ExclusionSets") as? Array<String>
    static let preferred_domain_controller = GetPreference(preference_key: "PreferredDC") as! String
    static let first_password = GetPreference(preference_key: "FirstPass") as! String
    static let method = GetPreference(preference_key: "Method") as! String
}

func macOSLAPS() {
    // Check if running as root
    let current_running_User = NSUserName()
    if current_running_User != "root" {
        laps_log.print("macOSLAPS needs to be run as root to ensure the password change for \(Constants.local_admin) if needed.", .error)
        exit(77)
    }
    // Remove files from extracting password if they exist
    if FileManager.default.fileExists(atPath: "/var/root/Library/Application Support/macOSLAPS-password") {
        do {
            try FileManager.default.removeItem(atPath: "/var/root/Library/Application Support/macOSLAPS-password")
            try FileManager.default.removeItem(atPath: "/var/root/Library/Application Support/macOSLAPS-expiration")
        } catch {
            laps_log.print("Unable to remove files used for extraction of password for MDM. Please delete manually", .warn)
        }
    }
    var pw_reset : Bool = false
    // Iterate through supported Arguments
    for argument in Constants.arguments {
        switch argument {
        case "-version":
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String
            print(appVersion)
            exit(0)
        case "-getPassword":
            if Constants.method == "Local" {
                let (current_password, _) = KeychainService.loadPassword(service: "macOSLAPS")
                if current_password == nil {
                    laps_log.print("Unable to retrieve password from macOSLAPS Keychain entry", .error)
                    exit(1)
                } else {
                    do {
                        let current_expiration_date = LocalTools.get_expiration_date()
                        let current_expiration_string = Constants.dateFormatter.string(for: current_expiration_date)
                        // Write contents to file
                        try current_password!.write(toFile: "/var/root/Library/Application Support/macOSLAPS-password", atomically: true, encoding: String.Encoding.utf8)
                        try current_expiration_string!.write(toFile: "/var/root/Library/Application Support/macOSLAPS-expiration", atomically: true, encoding: String.Encoding.utf8)
                    }
                    catch let error as NSError {
                        laps_log.print("Unable to extract password from keychain. Error: \(error)", .error)
                    }
                    exit(0)
                }
            } else {
                laps_log.print("Will not display password as our current method is Active Directory", .warn)
                exit(0)
            }
        case "-resetPassword":
            pw_reset = true
        default:
            continue
        }
    }
    switch Constants.method {
    case "AD":
        // Active Directory Password Change Function
        let ad_computer_record = ADTools.connect()
        // Get Expiration Time from Active Directory
        var ad_exp_time = ""
        if pw_reset == true {
            ad_exp_time = "126227988000000000"
        } else {
            ad_exp_time = ADTools.check_pw_expiration(computer_record: ad_computer_record)!
        }
        // Convert that time into a date
        let exp_date = TimeConversion.epoch(exp_time: ad_exp_time)
        // Compare that newly calculated date against now to see if a change is required
        if exp_date! < Date() {
            // Check if the domain controller that we are connected to is writable
            ADTools.verify_dc_writability(computer_record: ad_computer_record)
            // Performs Password Change for local admin account
            laps_log.print("Password Change is required as the LAPS password for \(Constants.local_admin), has expired", .info)
            ADTools.password_change(computer_record: ad_computer_record)
        }
        else {
            let actual_exp_date = Constants.dateFormatter.string(from: exp_date!)
            laps_log.print("Password change is not required as the password for \(Constants.local_admin) does not expire until \(actual_exp_date)", .info)
            exit(0)
        }
    case "Local":
        // Local method to perform passwords changes locally vs relying on Active Directory.
        // It is assumed that users will be using either an MDM or some reporting method to store
        // the password somewhere
        // Load the Keychain Item and compare the date
        var exp_date : Date?
        if pw_reset == true {
            exp_date = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        } else {
            exp_date = LocalTools.get_expiration_date()
        }
        if exp_date! < Date() {
            LocalTools.password_change()
            let new_exp_date = LocalTools.get_expiration_date()
            laps_log.print("Password change has been completed for the local admin \(Constants.local_admin). New expiration date is \(Constants.dateFormatter.string(from: new_exp_date!))", .info)
            exit(0)
        }
        else {
            laps_log.print("Password change is not required as the password for \(Constants.local_admin) does not expire until \(Constants.dateFormatter.string(from: exp_date!))", .info)
            exit(0)
        }
    default:
        exit(0)
    }
}

macOSLAPS()

///  ------------------------
///     LAPS for macOS Devices
///  ------------------------
///  Command line executable that handles automatic
///  generation and rotation of the local administrator
///  password.
///
///  Current Usage:
///    - Active Directory (Similar to Windows functionality)
///    - Local (Password stored in Keycahin Only)
///  -------------------------
///  Joshua D. Miller - josh@psu.edu
///  The Pennsylvania State University
///  Last Updated February 5, 2021
///  -------------------------

import Foundation

struct Constants {
    // Begin by setting our
    static let dateFormatter = date_formatter()
    // Read Command Line Arugments into array to use later
    static let arguments : Array = CommandLine.arguments
    // Retrieve our configuration for thte application or use the
    // default values
    static let local_admin = GetPreference(preference_key: "LocalAdminAccount") as! String
    static let password_lenth = GetPreference(preference_key: "PasswordLength") as! Int
    static let days_till_expiration = GetPreference(preference_key: "DaysTillExpiration") as! Int
    static let remove_keychain = GetPreference(preference_key: "RemoveKeychain") as! Bool
    static let characters_to_remove = GetPreference(preference_key: "RemovePassChars") as! String
    static let character_exclusion_sets = GetPreference(preference_key: "ExclusionSets") as? Array<String>
    static let preferred_domain_controller = GetPreference(preference_key: "PreferredDC") as! String
    static let first_password = GetPreference(preference_key: "FirstPass") as! String
    static let method = GetPreference(preference_key: "Method") as! String
}

func GetLocalExpirationDate() -> Date? {
    let (_, creation_date) = KeychainService.loadPassword(service: "macOSLAPS")
    // Convert the date we received to an acceptable format
    if creation_date == nil {
        return(nil)
    } else {
        guard let formatted_date = Constants.dateFormatter.date(from: creation_date!) else {
            // Print message we were unable to convert the date
            laps_log.print("Unable to unwrap the creation date form our keychain entry. Exiting...", .error)
            exit(1)
        }
        let exp_date = Calendar.current.date(byAdding: .day, value: Constants.days_till_expiration, to: formatted_date)!
        return exp_date
    }
}

// Active Directory Password Change Function
func ad_change(reset: Bool) {
    let ad_computer_record = ADTools.connect()
    // Get Expiration Time from Active Directory
    var ad_exp_time = ""
    if reset == true {
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
        PasswordChange.AD(computer_record: ad_computer_record)
    }
    else {
        let actual_exp_date = Constants.dateFormatter.string(from: exp_date!)
        laps_log.print("Password change is not required as the password for \(Constants.local_admin) does not expire until \(actual_exp_date)", .info)
        exit(0)
    }
}
// Local method to perform passwords changes locally vs relying on Active Directory.
// It is assumed that users will be using either an MDM or some reporting method to store
// the password somewhere
func local_change(reset: Bool) {
    // Load the Keychain Item and compare the date
    var exp_date : Date?
    if reset == true {
        exp_date = Calendar.current.date(byAdding: .day, value: -7, to: Date())
    } else {
        exp_date = GetLocalExpirationDate()
    }
    if exp_date! < Date() {
        PasswordChange.Local()
        let new_exp_date = GetLocalExpirationDate()
        laps_log.print("Password change has been completed for the local admin \(Constants.local_admin). New expiration date is \(Constants.dateFormatter.string(from: new_exp_date!))", .info)
        exit(0)
    }
    else {
        laps_log.print("Password change is not required as the password for \(Constants.local_admin) does not expire until \(Constants.dateFormatter.string(from: exp_date!))", .info)
        exit(0)
    }
}

func macOSLAPS() {
    // Check if running as root
    let current_running_User = NSUserName()
    if current_running_User != "root" {
        laps_log.print("macOSLAPS needs to be run as root to ensure the password change for \(Constants.local_admin) if needed.", .error)
        exit(1)
    }
    if Constants.arguments.contains("-version") {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String
        print(appVersion)
        exit(0)
    } else if Constants.arguments.contains("-getPassword") {
        if Constants.method == "local" {
            let (current_password, _) = KeychainService.loadPassword(service: "macOSLAPS")
            if current_password == nil {
                laps_log.print("Unable to retrieve password from macOSLAPS Keychain entry", .error)
                exit(1)
            } else {
                print(current_password!)
                exit(0)
            }
        } else {
            laps_log.print("Will not display password as our current method is Active Directory", .warn)
            exit(0)
        }
    } else if Constants.arguments.contains("-resetPassword") {
        if Constants.method == "AD" {
            ad_change(reset: true)
        } else if Constants.method == "local" {
            local_change(reset: true)
        }
    }
    if Constants.method == "AD" {
        ad_change(reset: false)
    } else if Constants.method == "local" {
        local_change(reset: false)
    }

}
macOSLAPS()

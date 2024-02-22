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
///  Last Updated February 21, 2024
///  -------------------------

import Foundation
import OpenDirectory

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
}
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
func macOSLAPS() {
    let output_dir = "/var/root/Library/Application Support"
    // Remove files from extracting password if they exist
    if FileManager.default.fileExists(atPath: "\(output_dir)/macOSLAPS-password") {
        do {
            try FileManager.default.removeItem(atPath: "/var/root/Library/Application Support/macOSLAPS-password")
            try FileManager.default.removeItem(atPath: "/var/root/Library/Application Support/macOSLAPS-expiration")
        } catch {
            laps_log.print("Unable to remove files used for extraction of password for MDM. Please delete manually", .warn)
        }
    }
    // Iterate through supported Arguments
    for argument in Constants.arguments {
        switch argument {
        case "-version":
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String
            print(appVersion)
            exit(0)
        case "-getpassword":
            verify_root()
            if Constants.method == "Local" {
                let (current_password, keychain_item_check) = KeychainService.loadPassword(service: "macOSLAPS")
                if current_password == nil && keychain_item_check == nil {
                    laps_log.print("Unable to retrieve password from macOSLAPS Keychain entry.", .error)
                    exit(1)
                } else if current_password == nil && keychain_item_check == "Not Found" {
                    laps_log.print("There does not appear to be a macOSLAPS Keychain Entry. Most likely, a password change has never been performed or the first password change has failed due to an incorrect password", .error)
                    exit(1)
                } else {
                    do {
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
                        guard (try? local_admin_record.verifyPassword(current_password!)) != nil
                        else {
                            laps_log.print("Password verification failed. Please use sysadminctl to reset. Exiting...")
                            exit(1)
                        }
                        laps_log.print("Password has been verified to work. Extracting...", .info)
                        let current_expiration_date = LocalTools.get_expiration_date()
                        let current_expiration_string = Constants.dateFormatter.string(for: current_expiration_date)
                        // Verify our output Directory exists and if not create it
                        var isDir:ObjCBool = true
                        // Write contents to file
                        if !FileManager.default.fileExists(atPath: output_dir, isDirectory: &isDir) {
                            do {
                                laps_log.print("Creating directory \(output_dir) as it does not currently exist. This issue was first present in macOS 12.2.1 on Apple Silicon", .warn)
                                try FileManager.default.createDirectory(atPath: output_dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
                                laps_log.print("Directory \(output_dir) has been created. Continuing...", .info)
                            } catch {
                                laps_log.print("An error occured attempting to create the directory \(output_dir). Unable to extract password. Exiting...", .error)
                                exit(0)
                            }
                        }
                        try current_password!.write(toFile: "/var/root/Library/Application Support/macOSLAPS-password", atomically: true, encoding: String.Encoding.utf8)
                        try current_expiration_string!.write(toFile: "/var/root/Library/Application Support/macOSLAPS-expiration", atomically: true, encoding: String.Encoding.utf8)
                        exit(0)
                    }
                    catch let error as NSError {
                        laps_log.print("Unable to extract password from keychain. Error: \(error)", .error)
                    }
                    exit(1)
                }
            } else {
                laps_log.print("Will not display password as our current method is Active Directory", .warn)
                exit(0)
            }
        case "-resetpassword":
            Constants.pw_reset = true
            
        case "-help":
            print("""
                  macOSLAPS Help
                  ==============
                  
                  These are the arguments that you can use with macOSLAPS.
                  
                  -version          Prints Current Version of macOSLAPS and gracefully exits
                  
                  -getpassword      If using the Local method, the password will be outputted
                                    to the filesystem temporarily. Password is deleted upon
                                    next automated or manual run
                  
                  -resetpassword    Forces a password reset no matter the expiration date
                  -firstpass        Performs a password reset using the FirstPass Configuration
                                    Profile key or the password you specify after this flag.
                                    The password of the admin MUST be this password or the
                                    change WILL FAIL.
                  
                  -help             Displays this screen
                  """)
            exit(0)
        case "-firstpass":
            Constants.pw_reset = true
            Constants.use_firstpass = true
            if Constants.first_password == "" {
                Constants.first_password = CommandLine.arguments[2]
            }
            if Constants.first_password == "" {
                laps_log.print("No password is specified via the FirstPass key OR in the command line. Exiting...", .error)
                exit(1)
            }
            laps_log.print("the -firstPass argument was invoked. Using the Configuration Profile specified password or the argument password that was specified.", .info)
        default:
            continue
        }
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

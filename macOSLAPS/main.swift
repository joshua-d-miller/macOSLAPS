//  LAPS for macOS devices
//
//  This script will set a randomly generated passsword for your local administrator
//  account on macOS if the expiration date has passed in your Active Directory. The results
//  will then be written to your AD into the attribute dsAttrTypeNative:ms-Mcs-AdmPwd to
//  mimic the same behavior of Local Adminsitrator Password Solution (LAPS) on Windows.
//  Once completed, an expiration date will then be set for the new password and written
//  to the AD attribute dsAttrTypeNative:ms-Mcs-AdmPwdself.expirationTime. This will allow
//  the LAPS UI to be utilized and the random password the ability to be seen by those with
//  permission to retrieve it.
//  Joshua D. Miller - josh@psu.edu - The Pennsylvania State University
//  Last Update June 13, 2017

import Foundation

// Date Formatting for application
let dateFormatter = date_formatter()

// Main function that checks our local admin password expiration in Active Directory and then if
// needed changes the password to something random and writes it back to Active Directory
func macOSLAPS() {
    // Let's get started with getting our local admin account name
    let local_admin = get_config_settings(preference_key: "LocalAdminAccount") as! String
    // Connect to Active Directory
    let computer_record = connect_to_ad()
    // Get Expiration Time from Active Directory
    let exp_time = ad_tools(computer_record: computer_record, tool: "Expiration Time", password: nil, new_ad_exp_date: nil)
    // Convert that time into a date
    let exp_date = time_conversion(time_type: "epoch", exp_time: exp_time, exp_days: nil) as! Date
    // Compare that newly calculated date against now to see if a change is required
    if exp_date < Date() {
        // Performs Password Change for local admin account
        perform_password_change(computer_record: computer_record, local_admin: local_admin)
    }
    else {
        let actual_exp_date = dateFormatter.string(from: exp_date)
        laps_log.print("Password change is not required as the password for " + local_admin + " does not expire until " + actual_exp_date, .info)
        exit(0)
    }

}

macOSLAPS()

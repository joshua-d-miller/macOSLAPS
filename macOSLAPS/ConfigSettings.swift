//
//  ConfigSettings.swift
//  macOSLAPS
//
//  Created by Joshua D. Miller on 6/13/17.
//  The Pennsylvania State University
//

import Foundation

// Default Configuration Variables
var bundle_id = "edu.psu.macoslaps"
var defaultpreferences = [
    "LocalAdminAccount":"admin",
    "PasswordLength":12,
    "DaysTillExpiration":60,
    "RemoveKeychain":true,
    "RemovePassChars": "\'",
    "ExclusionSets": []
    ] as [String : Any]

// Pull configuration settings from managed preferences or set defaults
func get_config_settings(preference_key: String) -> Any? {
    let bundle_plist = UserDefaults.init(suiteName: bundle_id)
    var preference_value = bundle_plist?.value(forKey: preference_key)
    if preference_value == nil {
        preference_value = defaultpreferences[preference_key]
        return(preference_value)!
    }
    return(preference_value)!
}

///
///  Generate Password.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///
///  Last updated: November 9, 2026
///
///  Builds a PasswordPolicy from the preferences and generates a password with
///  PasswordGenerator (Extensions/PasswordPolicy.swift). Fixes #109, #93, #121:
///  exact length, requirements always met, every excluded character honored.

import Foundation

func currentPasswordPolicy(length: Int) -> PasswordPolicy {
    var style = (GetPreference(preference_key: "PasswordStyle") as? String ?? "random").lowercased()
    if style == "passphrase" {
        laps_log.print("PasswordStyle passphrase is not available in this build yet. Using readable.", .warn)
        style = "readable"
    } else if style != "random" && style != "readable" {
        laps_log.print("Unknown PasswordStyle \"\(style)\". Using random.", .warn)
        style = "random"
    }
    var grouping = GetPreference(preference_key: "PasswordGrouping") as! Int
    var separator = GetPreference(preference_key: "PasswordSeparator") as! String
    // Readable passwords are meant to be read aloud: group them by 4 unless told otherwise.
    if style == "readable" && grouping == 0 {
        grouping = 4
        if separator.isEmpty { separator = "-" }
    }
    return PasswordPolicy(
        length: length,
        excludedCharacters: Set(Constants.characters_to_remove),
        exclusionSets: Constants.character_exclusion_sets ?? [],
        requirements: Constants.passwordrequirements,
        grouping: grouping,
        separator: separator,
        style: style
    )
}

// Generate a randomized password from printable ASCII using the configured policy
func PasswordGen(length: Int) -> String {
    let policy = currentPasswordPolicy(length: length)
    for name in policy.unknownExclusionSets {
        laps_log.print("Unknown ExclusionSets value \"\(name)\" ignored. Valid values: symbols, letters, numbers.", .warn)
    }
    do {
        return try PasswordGenerator.generate(policy: policy)
    } catch {
        laps_log.print("Unable to generate a password: \(error). Please adjust your password settings.", .error)
        exit(1)
    }
}

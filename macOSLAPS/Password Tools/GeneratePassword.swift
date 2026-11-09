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
    return PasswordPolicy(
        length: length,
        excludedCharacters: Set(Constants.characters_to_remove),
        exclusionSets: Constants.character_exclusion_sets ?? [],
        requirements: Constants.passwordrequirements,
        grouping: GetPreference(preference_key: "PasswordGrouping") as! Int,
        separator: GetPreference(preference_key: "PasswordSeparator") as! String
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

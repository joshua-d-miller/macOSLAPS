///
///  CharacterSetExlusion.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 7/7/17.
///
///

import Foundation

func CharacterSetExclusions(password_chars: String) -> String {
    // New exclusion that will remove a specified CharacterSet
    // From Using CharacterSets in Swift - https://medium.com/@jacqschweiger/using-character-sets-in-swift-945b99ba17e
    let exclusion_sets = Constants.character_exclusion_sets
    if !(exclusion_sets?.isEmpty)! {
        var filtered_pw_chars = ""
        for item in exclusion_sets! {
            if item == "symbols" {
                filtered_pw_chars = password_chars.components(separatedBy: CharacterSet.punctuationCharacters).joined().components(separatedBy: CharacterSet.symbols).joined()
            }
            else if item == "letters" {
                filtered_pw_chars = password_chars.components(separatedBy: CharacterSet.letters).joined()
            }
            else if item == "numbers" {
                filtered_pw_chars = password_chars.components(separatedBy: CharacterSet.decimalDigits).joined()
            }
        }
        return(filtered_pw_chars)
    }
    else {
        return(password_chars)
    }
}

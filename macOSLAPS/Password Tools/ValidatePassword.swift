///
///  ValidatePassword.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 3/17/22.
///
///  Last Updated February 21, 2022

import Foundation

func ValidatePassword (generated_password: String) -> Bool {
    // Set Counters
    var lowercase_count:Int = 0
    var uppercase_count:Int = 0
    var number_count:Int = 0
    var symbol_count:Int = 0
    // Loop through password charactersand determine type of character
    for char in generated_password {
        // Count lowercase letters
        if char.isLowercase {
            lowercase_count += 1
            // Count uppercase letters
        } else if char.isUppercase {
            uppercase_count += 1
            // Count numbers
        } else if char.isNumber {
            number_count += 1
            // Count symbols
        } else if char.isSymbol || char.isPunctuation {
            symbol_count += 1
        }
    }
    // Do we match the requirements
        if lowercase_count >= Constants.passwordrequirements["Lowercase"]! && uppercase_count >= Constants.passwordrequirements["Uppercase"]! &&
        number_count >= Constants.passwordrequirements["Number"]! &&
        symbol_count >= Constants.passwordrequirements["Symbol"]! {
            return true
    } else {
            return false
    }
}

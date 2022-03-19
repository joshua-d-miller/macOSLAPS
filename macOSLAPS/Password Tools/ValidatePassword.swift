///
///  ValidatePassword.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 3/17/22.
///
///  Rreference: https://stackoverflow.com/questions/39284607/how-to-implement-a-regex-for-password-validation-in-swift
///  Last Updated March 18, 2022

import Foundation

func ValidatePassword (generated_password: String) -> Bool {
    // Build the Regex to be used
    var lowercase_regex = ""
    var uppercase_regex = ""
    var number_regex = ""
    var symbol_regex = ""
    
    if Constants.passwordrequirements["Lowercase"] as! Int != 0 {
        lowercase_regex = "(?=" + String.init(repeating: ".*[a-z]", count: Constants.passwordrequirements["Lowercase"] as! Int) + ")"
    }
    if Constants.passwordrequirements["Uppercase"] as! Int != 0 {
        uppercase_regex = "(?=" + String.init(repeating: ".*[A-Z]", count: Constants.passwordrequirements["Uppercase"] as! Int) + ")"
    }
    if Constants.passwordrequirements["Number"] as! Int != 0 {
        number_regex = "(?=" + String.init(repeating: ".*[0-9]", count: Constants.passwordrequirements["Number"] as! Int) + ")"
    }
    if Constants.passwordrequirements["Symbol"] as! Int != 0 {
        symbol_regex = "(?=" + String.init(repeating: "[.*! \"#$%&'()*+,-./:;<=>?@\\[\\\\\\]^_`{|}~]", count: Constants.passwordrequirements["Symbol"] as! Int) + ")"
    }
    var full_regex = "^" + lowercase_regex + uppercase_regex + number_regex + symbol_regex + ".{\(Constants.password_length)}$"
    if full_regex.count < 8 {
        full_regex = ".*"
    }
    let password_check = NSPredicate(format: "SELF MATCHES %@", full_regex)
    return password_check.evaluate(with: generated_password)
}

///
///  Generate Password.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///
///  Last updated: February 21, 2024

import Foundation

// Generate a randomized password using the ASCII Character Set
func PasswordGen(length: Int) -> String {
    // Variables
    var password_try:Int = 0
    var final_password:String = ""
    var password_verified:Bool = false
    // Get Password Characters
    var get_passwordCharacters = [] as Array<Character>
    for c in 33 ..< 127 {
        let char = Character(UnicodeScalar(c)!)
        get_passwordCharacters.append(char)
    }
    // Exclude Character Sets specified
    var string_passwordCharacters = String(get_passwordCharacters)
    string_passwordCharacters = CharacterSetExclusions(password_chars: string_passwordCharacters)
    // Exclude Characters specified in string format. If any characters are specified that
    // require escape make sure the escape is there as well (Examples: \\ \")
    var passwordCharacters = Array(string_passwordCharacters)
    for character in Constants.characters_to_remove {
        if let ix = passwordCharacters.firstIndex(of: character) {
            passwordCharacters.remove(at: ix)
        }
    }
    var generated_passwords = [] as Array
    // Try to generate and verify the password meets the requirements specified if any
    while password_try <= 10 && password_verified != true  {
        // Generate 10 Random Passwords
        for _ in 0..<10 {
            var random_password = ""
            // Generate a Randomized Password
            for _ in 0..<length {
                let rand = arc4random_uniform(UInt32(passwordCharacters.count))
                random_password.append(passwordCharacters[Int(rand)])
                passwordCharacters.shuffle()
            }
            generated_passwords.append(random_password)
        }
        // Select one of those random passwords
        final_password = generated_passwords.randomItem() as! String
        // Verify
        password_verified = ValidatePassword(generated_password: final_password)
        password_try += 1
    }
    if password_verified == false {
        laps_log.print("We were unable to generate a password with the requirements specified. Please adjust the requirements or increase the length to ensure we can meet the requirements.", .error)
        exit(1)
    } else {
        laps_log.print("Password has been verified to meet the requirements specified in configuration.", .info)
    }
    let password_grouping = GetPreference(preference_key: "PasswordGrouping") as! Int
    if (password_grouping > 0) {
        let chunks = stride(from: 0, to: final_password.count, by: password_grouping).map { (offset) -> Substring in
            let start = final_password.index(final_password.startIndex, offsetBy: offset)
            let end = final_password.index(start, offsetBy: password_grouping, limitedBy: final_password.endIndex) ?? final_password.endIndex
            return final_password[start..<end]
        }
        return chunks.joined(separator: GetPreference(preference_key: "PasswordSeparator") as! String)
    } else {
        return final_password
    }
}

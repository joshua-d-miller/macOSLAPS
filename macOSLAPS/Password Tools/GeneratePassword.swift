///
///  Generate Password.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///
///  Last updated: February 26, 2024

import Foundation

// Generate a randomized password using the ASCII Character Set
func PasswordGen(length: Int) -> String {
    // Variables
    var final_password:String = ""
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
    // Generate 10 Random Passwords
    while generated_passwords.count < 10 {
        var random_password = ""
        // Determine requirements and put them into a string
        if Constants.passwordrequirements.isEmpty == false {
            // Set Counts to 0
            var lowerletter_count: Int = 0
            var upperletter_count: Int = 0
            var number_count: Int = 0
            var symbol_count: Int = 0
            // While loop while the counts we have are not equal to the requirements in the password
            while lowerletter_count != Constants.passwordrequirements["Lowercase"] && upperletter_count != Constants.passwordrequirements["Uppercase"] && number_count != Constants.passwordrequirements["Numbers"] &&
                    symbol_count != Constants.passwordrequirements["Symbols"] {
                let random_char = passwordCharacters.randomItem()
                // Is the character a lower case letter?
                if random_char.isLowercase {
                    lowerletter_count += 1
                }
                else if random_char.isUppercase {
                    upperletter_count += 1
                }
                // Is the character a number?
                else if random_char.isNumber {
                    number_count += 1
                }
                // Is the character a symbol?
                else if random_char.isSymbol {
                    symbol_count += 1
                }
                random_password.append(random_char)
            }
        }
        // Mix up our requirements we gathered
        if !random_password.isEmpty {
            random_password = String(random_password.shuffled())
        }
        // Generate a Randomized Password
        while random_password.count <= length {
            let rand = arc4random_uniform(UInt32(passwordCharacters.count))
            random_password.append(passwordCharacters[Int(rand)])
            passwordCharacters.shuffle()
        }
        // Shuffle one more time for good measure
        random_password = String(random_password.shuffled())
        generated_passwords.append(random_password)
    }
    // Select one of those random passwords
    final_password = generated_passwords.randomItem() as! String
    // Perform Grouping if needed
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

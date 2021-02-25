///
///  Generate Password.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///  The Pennsylvania State University
///

import Foundation

// Generate a randomized password using the ASCII Character Set
func PasswordGen(length: Int) -> String {
    var get_passwordCharacters = [] as Array<Character>
    for c in 33 ..< 127 {
        let char = Character(UnicodeScalar(c)!)
        get_passwordCharacters.append(char)
    }
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
    for _ in 0..<10 {
        var random_password = ""
        // Generate a Randomized Password
        for _ in 0..<length {
            let rand = arc4random_uniform(UInt32(passwordCharacters.count))
            random_password.append(passwordCharacters[Int(rand)])
        }
        generated_passwords.append(random_password)
    }
    // Select one of those random passwords
    let final_password = generated_passwords.randomItem() as! String
    return(final_password)
}

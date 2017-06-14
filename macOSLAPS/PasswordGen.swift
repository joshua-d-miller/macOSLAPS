//
//  PasswordGen.swift
//  macOSLAPS
//
//  Created by Joshua D. Miller on 6/13/17.
//  The Pennsylvania State University
//

import Foundation

// Generate a randomized password using the ASCII Character Set
func generate_random_pw(length: Int) -> String {
    var passwordCharacters = [] as Array<Character>
    for c in 33 ..< 127 {
        let char = Character(UnicodeScalar(c)!)
        passwordCharacters.append(char)
    }
    // Exclude Characters specified in string format. If any characters are specified that
    // require escape make sure the escape is there as well (Examples: \\ \")
    let exclusions_from_pw = get_config_settings(preference_key: "RemovePassChars") as! String
    for character in exclusions_from_pw.characters {
        if let ix = passwordCharacters.index(of: character) {
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

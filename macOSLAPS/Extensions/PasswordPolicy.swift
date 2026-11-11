/*
===============================================================================
 macOSLAPS | Extensions | PasswordPolicy.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2017-07-07
 Updated:   2026-11-11

 Purpose:
     Password generation, depending only on Foundation so the unit tests
     in Tests/GeneratorTests compile it without root, Open Directory or
     the rest of macOSLAPS. Started as CharacterSetExlusion.swift.

 Rules:
     Printable ASCII 33-126 only (no spaces, no Unicode).
     length counts generated characters; grouping separators are extra (12
     grouped by 4 is xxxx-xxxx-xxxx).
     Each PasswordRequirements count is a minimum and is always met.
     Excluded characters and exclusion sets are always honored; separators
     are excluded automatically when grouping.
     Impossible policies throw instead of looping or ignoring rules.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    Rewritten: exact length, requirements always
                        claude    met, every excluded character honored (#109,
                                  #93, #121); readable style.

                                  New header and section style.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------------- //
// | Character classes | //
// --------------------- //
// Uppercase, lowercase, numbers and symbols.                                //
enum PasswordCharacterClass: String, CaseIterable {
    case Uppercase, Lowercase, Number, Symbol

    func contains(_ character: Character) -> Bool {
        guard let a = character.asciiValue, (33...126).contains(a) else { return false }
        switch self {
        case .Uppercase: return (65...90).contains(a)
        case .Lowercase: return (97...122).contains(a)
        case .Number:    return (48...57).contains(a)
        case .Symbol:    return !(65...90).contains(a) && !(97...122).contains(a) && !(48...57).contains(a)
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------- //
// | Policy | //
// ---------- //
// What a password must and must not contain.                                //
struct PasswordPolicy {
    var length: Int
    var excludedCharacters: Set<Character> = []
    var exclusionSets: [String] = []
    /// Keyed by PasswordCharacterClass raw value. Missing keys mean 0.
    var requirements: [String : Int] = [:]
    var grouping: Int = 0
    var separator: String = "-"
    /// "random" (printable ASCII) or "readable" (letters and digits without look-alikes).
    var style: String = "random"

    /// Characters that are easy to confuse when read aloud or typed: 0 O o 1 l I.
    static let lookAlikes : Set<Character> = ["0", "O", "o", "1", "l", "I"]

    static let knownExclusionSets: Set<String> = ["symbols", "letters", "numbers"]

    var usesGrouping: Bool { grouping > 0 && grouping < length && !separator.isEmpty }

    /// Exclusion set names that are not recognized (they are ignored).
    var unknownExclusionSets: [String] {
        exclusionSets.filter { !PasswordPolicy.knownExclusionSets.contains($0.lowercased()) }
    }

    /// Every character the password may contain.
    var alphabet: [Character] {
        var excludedClasses = Set<PasswordCharacterClass>()
        for set in exclusionSets {
            switch set.lowercased() {
            case "symbols": excludedClasses.insert(.Symbol)
            case "letters": excludedClasses.formUnion([.Uppercase, .Lowercase])
            case "numbers": excludedClasses.insert(.Number)
            default: break
            }
        }
        var excluded = excludedCharacters
        if usesGrouping { excluded.formUnion(separator) }
        if style.lowercased() == "readable" {
            excludedClasses.insert(.Symbol)
            excluded.formUnion(PasswordPolicy.lookAlikes)
        }
        return (33...126).map { Character(UnicodeScalar(UInt8($0))) }.filter { c in
            !excluded.contains(c) && !excludedClasses.contains { $0.contains(c) }
        }
    }

    func requiredCount(_ cls: PasswordCharacterClass) -> Int {
        max(0, requirements[cls.rawValue] ?? 0)
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------- //
// | Errors | //
// ---------- //
// Policies that can't be met, with a message for the log.                   //
enum PasswordGenerationError: Error, CustomStringConvertible, Equatable {
    case invalidLength(Int)
    case emptyAlphabet
    case requirementUnsatisfiable(String)
    case requirementsExceedLength(required: Int, length: Int)
    case validationFailed(String)

    var description: String {
        switch self {
        case .invalidLength(let n):
            return "PasswordLength must be at least 1 (got \(n))."
        case .emptyAlphabet:
            return "RemovePassChars and ExclusionSets remove every possible character."
        case .requirementUnsatisfiable(let cls):
            return "PasswordRequirements asks for \(cls) characters, but RemovePassChars/ExclusionSets remove all of them."
        case .requirementsExceedLength(let required, let length):
            return "PasswordRequirements add up to \(required) characters, which is more than PasswordLength (\(length))."
        case .validationFailed(let reason):
            return "Generated password failed validation: \(reason)."
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------- //
// | Generator | //
// ------------- //
// Picks the required characters first, fills the rest, shuffles and groups. //
enum PasswordGenerator {
    static func generate(policy: PasswordPolicy) throws -> String {
        var rng = SystemRandomNumberGenerator()
        return try generate(policy: policy, using: &rng)
    }

    static func generate<R: RandomNumberGenerator>(policy: PasswordPolicy, using rng: inout R) throws -> String {
        guard policy.length >= 1 else { throw PasswordGenerationError.invalidLength(policy.length) }
        let alphabet = policy.alphabet
        guard !alphabet.isEmpty else { throw PasswordGenerationError.emptyAlphabet }

        // Check everything before generating anything.
        var pools : [(PasswordCharacterClass, [Character], Int)] = []
        var required = 0
        for cls in PasswordCharacterClass.allCases {
            let count = policy.requiredCount(cls)
            guard count > 0 else { continue }
            let pool = alphabet.filter { cls.contains($0) }
            guard !pool.isEmpty else { throw PasswordGenerationError.requirementUnsatisfiable(cls.rawValue) }
            pools.append((cls, pool, count))
            required += count
        }
        guard required <= policy.length else {
            throw PasswordGenerationError.requirementsExceedLength(required: required, length: policy.length)
        }

        var characters : [Character] = []
        characters.reserveCapacity(policy.length)
        for (_, pool, count) in pools {
            for _ in 0..<count { characters.append(pool.randomElement(using: &rng)!) }
        }
        while characters.count < policy.length {
            characters.append(alphabet.randomElement(using: &rng)!)
        }
        characters.shuffle(using: &rng)

        var password = String(characters)
        if policy.usesGrouping {
            password = stride(from: 0, to: characters.count, by: policy.grouping).map { start in
                String(characters[start..<min(start + policy.grouping, characters.count)])
            }.joined(separator: policy.separator)
        }
        try validate(password, policy: policy)
        return password
    }

    /// Independent check of every rule. Used after generation and by the tests.
    static func validate(_ password: String, policy: PasswordPolicy) throws {
        var body = password
        if policy.usesGrouping {
            let groups = password.components(separatedBy: policy.separator)
            guard groups.dropLast().allSatisfy({ $0.count == policy.grouping }),
                  let last = groups.last, (1...policy.grouping).contains(last.count) else {
                throw PasswordGenerationError.validationFailed("grouping does not match PasswordGrouping")
            }
            body = groups.joined()
        }
        guard body.count == policy.length else {
            throw PasswordGenerationError.validationFailed("length \(body.count), expected \(policy.length)")
        }
        let allowed = Set(policy.alphabet)
        guard body.allSatisfy({ allowed.contains($0) }) else {
            throw PasswordGenerationError.validationFailed("contains a character outside the allowed set")
        }
        for cls in PasswordCharacterClass.allCases {
            let have = body.filter { cls.contains($0) }.count
            guard have >= policy.requiredCount(cls) else {
                throw PasswordGenerationError.validationFailed("\(have) \(cls.rawValue), requires \(policy.requiredCount(cls))")
            }
        }
    }
}

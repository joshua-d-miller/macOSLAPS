/*
===============================================================================
 macOSLAPS | Tests | main.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-09
 Updated:   2026-11-11

 Purpose:
     Unit tests for PasswordGenerator
     (macOSLAPS/Extensions/PasswordPolicy.swift). No Xcode project or root
     needed.

 Usage:
     swiftc -O macOSLAPS/Extensions/PasswordPolicy.swift \
         Tests/GeneratorTests/main.swift -o generator-tests
     ./generator-tests
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   joshua    New file.
                        claude
                                  New header and section style.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------- //
// | Checks | //
// ---------- //
// Counting checks and failures.                                             //
var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL: \(message())")
    }
}

func expectThrows(_ policy: PasswordPolicy, _ expected: PasswordGenerationError, _ name: String) {
    do {
        let pw = try PasswordGenerator.generate(policy: policy)
        expect(false, "\(name): expected \(expected), got password of length \(pw.count)")
    } catch let error as PasswordGenerationError {
        expect(error == expected, "\(name): expected \(expected), got \(error)")
    } catch {
        expect(false, "\(name): unexpected error \(error)")
    }
}

func generateOrFail(_ policy: PasswordPolicy, _ name: String) -> String? {
    do {
        return try PasswordGenerator.generate(policy: policy)
    } catch {
        expect(false, "\(name): \(error)")
        return nil
    }
}

func count(_ s: String, _ cls: PasswordCharacterClass) -> Int { s.filter { cls.contains($0) }.count }

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------------- //
// | Issue regressions | //
// --------------------- //
// #109, #93 and requirement counts.                                         //

// #121 / #109: exact length, no off-by-one.
for length in [1, 8, 12, 16, 17, 64] {
    if let pw = generateOrFail(PasswordPolicy(length: length), "length \(length)") {
        expect(pw.count == length, "length \(length): got \(pw.count)")
    }
}

// #109: the reporter's exact settings. 12 characters in groups of 4, separators extra, and
// every character in RemovePassChars honored (they saw `_` and `{`).
let issue109 = PasswordPolicy(length: 12, excludedCharacters: Set("{)^'\"}):;<|>,/\\-.+~`_"),
                              grouping: 4, separator: "-")
for i in 0..<2000 {
    guard let pw = generateOrFail(issue109, "#109 run \(i)") else { break }
    expect(pw.count == 14, "#109: \(pw) has length \(pw.count), expected 14 (12 + 2 separators)")
    let groups = pw.split(separator: "-", omittingEmptySubsequences: false)
    expect(groups.count == 3 && groups.allSatisfy { $0.count == 4 }, "#109: bad grouping \(pw)")
    let body = groups.joined()
    expect(!body.contains(where: { issue109.excludedCharacters.contains($0) }), "#109: excluded character in \(pw)")
}

// #93: 2 of each class in 14 characters must always succeed and be satisfied.
let issue93 = PasswordPolicy(length: 14, excludedCharacters: Set("{}[]|"),
                             requirements: ["Lowercase": 2, "Uppercase": 2, "Number": 2, "Symbol": 2])
for i in 0..<2000 {
    guard let pw = generateOrFail(issue93, "#93 run \(i)") else { break }
    for cls in PasswordCharacterClass.allCases {
        expect(count(pw, cls) >= 2, "#93: \(pw) has \(count(pw, cls)) \(cls.rawValue)")
    }
}

// Requirement of exactly one class must not stop the others being met (old && loop bug).
let single = PasswordPolicy(length: 12, requirements: ["Uppercase": 1, "Number": 3])
for _ in 0..<2000 {
    guard let pw = generateOrFail(single, "single") else { break }
    expect(count(pw, .Uppercase) >= 1 && count(pw, .Number) >= 3, "requirements not met: \(pw)")
}

// Multiple ExclusionSets all apply (old code only applied the last).
let noLettersNoSymbols = PasswordPolicy(length: 20, exclusionSets: ["symbols", "letters"])
for _ in 0..<500 {
    guard let pw = generateOrFail(noLettersNoSymbols, "exclusion sets") else { break }
    expect(pw.allSatisfy { $0.isASCII && $0.isNumber }, "exclusion sets: \(pw) is not digits only")
}

// #118: printable ASCII only.
for _ in 0..<2000 {
    guard let pw = generateOrFail(PasswordPolicy(length: 32), "ascii") else { break }
    expect(pw.unicodeScalars.allSatisfy { (33...126).contains($0.value) }, "non-printable or non-ASCII in \(pw.debugDescription)")
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------ //
// | Readable style | //
// ------------------ //
// Grouped, without look-alike characters.                                   //
let readable = PasswordPolicy(length: 16, grouping: 4, separator: "-", style: "readable")
for _ in 0..<2000 {
    guard let pw = generateOrFail(readable, "readable") else { break }
    let body = pw.replacingOccurrences(of: "-", with: "")
    expect(body.count == 16 && body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, "readable: \(pw)")
    expect(!body.contains(where: { PasswordPolicy.lookAlikes.contains($0) }), "readable has a look-alike: \(pw)")
}
expectThrows(PasswordPolicy(length: 12, requirements: ["Symbol": 1], style: "readable"),
             .requirementUnsatisfiable("Symbol"), "readable with a symbol requirement")

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------------------- //
// | Impossible policies throw | //
// ----------------------------- //

expectThrows(PasswordPolicy(length: 0), .invalidLength(0), "zero length")
expectThrows(PasswordPolicy(length: 8, exclusionSets: ["symbols", "letters", "numbers"]), .emptyAlphabet, "empty alphabet")
expectThrows(PasswordPolicy(length: 8, exclusionSets: ["symbols"], requirements: ["Symbol": 1]),
             .requirementUnsatisfiable("Symbol"), "symbol required but excluded")
expectThrows(PasswordPolicy(length: 6, requirements: ["Uppercase": 3, "Number": 4]),
             .requirementsExceedLength(required: 7, length: 6), "requirements exceed length")

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------------- //
// | Grouping edge cases | //
// ----------------------- //

if let pw = generateOrFail(PasswordPolicy(length: 10, grouping: 4, separator: "-"), "uneven groups") {
    expect(pw.count == 12 && pw.split(separator: "-").map(\.count) == [4, 4, 2], "uneven grouping: \(pw)")
}
// "-" is an ordinary character when no grouping happens, so exclude it to make the check meaningful.
if let pw = generateOrFail(PasswordPolicy(length: 8, excludedCharacters: ["-"], grouping: 8, separator: "-"), "group >= length") {
    expect(pw.count == 8 && !pw.contains("-"), "grouping >= length should not add separators: \(pw)")
}
// The separator is never used as a password character when grouping.
for _ in 0..<500 {
    guard let pw = generateOrFail(PasswordPolicy(length: 16, grouping: 4, separator: "-"), "separator excluded") else { break }
    expect(pw.filter { $0 == "-" }.count == 3, "separator appears inside a group: \(pw)")
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------------------- //
// | Randomized property test | //
// ---------------------------- //
// Random policies; every rule must hold on every password.                  //

var rng = SystemRandomNumberGenerator()
let sets = ["symbols", "letters", "numbers"]
var generated = 0
for _ in 0..<10_000 {
    let length = Int.random(in: 1...40, using: &rng)
    var policy = PasswordPolicy(length: length)
    policy.excludedCharacters = Set((0..<Int.random(in: 0...15, using: &rng)).map { _ in
        Character(UnicodeScalar(UInt8.random(in: 33...126, using: &rng)))
    })
    if Bool.random(using: &rng) { policy.exclusionSets = [sets.randomElement(using: &rng)!] }
    for cls in PasswordCharacterClass.allCases where Bool.random(using: &rng) {
        policy.requirements[cls.rawValue] = Int.random(in: 0...3, using: &rng)
    }
    if Bool.random(using: &rng) {
        policy.grouping = Int.random(in: 1...8, using: &rng)
        policy.separator = ["-", "_", ".", " "].randomElement(using: &rng)!
    }
    do {
        let pw = try PasswordGenerator.generate(policy: policy)
        try PasswordGenerator.validate(pw, policy: policy)
        generated += 1
    } catch PasswordGenerationError.validationFailed(let reason) {
        expect(false, "property: \(reason) for \(policy)")
    } catch {
        // An impossible policy may throw, but only for a reason that is really true.
        if case PasswordGenerationError.requirementsExceedLength(let required, _) = error {
            expect(required > policy.length, "property: wrongly rejected \(policy)")
        }
    }
}
expect(generated > 5_000, "property: only \(generated) of 10000 random policies generated")

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

///
///  Preferences.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 6/13/17.
///
///  Last Updated November 8, 2026
///
///  Preference domains
///  ------------------
///  macOSLAPS is moving from the original `edu.psu.macoslaps` domain to
///  `preferenceDomain` below. Both are read so existing deployments keep
///  working; the keys are identical, only the domain (profile PayloadType)
///  changes. The domain actually used is chosen as a whole (keys are never
///  mixed between the two), in this order:
///
///    1. new domain, managed (configuration profile)
///    2. legacy domain, managed (configuration profile)
///    3. new domain, unmanaged (/Library/Preferences)
///    4. legacy domain, unmanaged (/Library/Preferences)
///    5. built-in defaults
///
///  Values are coerced to the expected type so a value written with the
///  wrong type (e.g. `defaults write ... PasswordLength 14` without -int)
///  is converted or replaced by the default with a warning instead of
///  crashing the process (issue #86).

import Foundation

// New preference domain. Configuration profiles should use this as their PayloadType.
let preferenceDomain = "com.joshua-d-miller.macoslaps"
// Original domain. Still read for compatibility; logs a deprecation warning when used.
let legacyPreferenceDomain = "edu.psu.macoslaps"

// Default Configuration Variables
var defaultpreferences : [ String : Any ] = [
    "LocalAdminAccount"      :       "admin",
    "PasswordLength"         :       12,
    "PasswordGrouping"       :       0,
    "PasswordSeparator"      :       "-",
    "DaysTillExpiration"     :       60,
    "RemoveKeychain"         :       true,
    "RemovePassChars"        :       "\'",
    "ExclusionSets"          :       [String](),
    "PreferredDC"            :       "",
    "FirstPass"              :       "",
    "Method"                 :       "AD",
    "PasswordRequirements"   :       [
        "Uppercase"          :       0,
        "Lowercase"          :       0,
        "Number"             :       0,
        "Symbol"             :       0
        ],
    ]

// Misspellings seen in the wild, mapped to the real key. Read only when the real key is absent.
let preferenceKeyAliases : [ String : String ] = [
    "PasswordSeperator"      :       "PasswordSeparator",
]

// Canonical names for PasswordRequirements sub-keys (matched case-insensitively).
let requirementKeyAliases : [ String : String ] = [
    "uppercase" : "Uppercase", "upper" : "Uppercase",
    "lowercase" : "Lowercase", "lower" : "Lowercase",
    "number"    : "Number",    "numbers" : "Number",
    "symbol"    : "Symbol",    "symbols" : "Symbol",
]

// Keys whose values must never be printed.
let secretPreferenceKeys : Set<String> = ["FirstPass"]

enum PreferenceSource: String {
    case managedNew      = "configuration profile (new domain)"
    case managedLegacy   = "configuration profile (legacy edu.psu.macoslaps domain)"
    case unmanagedNew    = "/Library/Preferences (new domain)"
    case unmanagedLegacy = "/Library/Preferences (legacy edu.psu.macoslaps domain)"
    case defaults        = "built-in defaults"
}

final class PreferenceStore {
    static let shared = PreferenceStore()

    let domain : String
    let source : PreferenceSource
    private let store : UserDefaults?
    private var warned = Set<String>()

    private init() {
        let newStore = UserDefaults(suiteName: preferenceDomain)
        let legacyStore = UserDefaults(suiteName: legacyPreferenceDomain)
        let knownKeys = Array(defaultpreferences.keys) + Array(preferenceKeyAliases.keys)

        func isManaged(_ d: UserDefaults?) -> Bool {
            guard let d = d else { return false }
            return knownKeys.contains { d.objectIsForced(forKey: $0) }
        }
        func hasAnyValue(_ d: UserDefaults?) -> Bool {
            guard let d = d else { return false }
            return knownKeys.contains { d.object(forKey: $0) != nil }
        }

        let newManaged = isManaged(newStore)
        let legacyManaged = isManaged(legacyStore)

        let chosen : (String, PreferenceSource, UserDefaults?)
        if newManaged {
            chosen = (preferenceDomain, .managedNew, newStore)
        } else if legacyManaged {
            chosen = (legacyPreferenceDomain, .managedLegacy, legacyStore)
        } else if hasAnyValue(newStore) {
            chosen = (preferenceDomain, .unmanagedNew, newStore)
        } else if hasAnyValue(legacyStore) {
            chosen = (legacyPreferenceDomain, .unmanagedLegacy, legacyStore)
        } else {
            chosen = (preferenceDomain, .defaults, nil)
        }
        domain = chosen.0
        source = chosen.1
        store = chosen.2

        if newManaged && legacyManaged {
            laps_log.print("Configuration profiles exist for both \(preferenceDomain) and \(legacyPreferenceDomain). Using \(preferenceDomain); the legacy profile is ignored and can be removed.", .warn)
        }
        if source == .managedLegacy || source == .unmanagedLegacy {
            laps_log.print("Settings are being read from the legacy domain \(legacyPreferenceDomain). This still works, but please move your configuration to \(preferenceDomain) (same keys, new PayloadType). Legacy support will be removed in a future major release.", .warn)
        }
        if source == .defaults {
            laps_log.print("No macOSLAPS settings found in \(preferenceDomain) or \(legacyPreferenceDomain). Using built-in defaults.", .warn)
        }
    }

    /// Raw value for a key from the chosen domain, falling back to a known misspelling.
    func rawValue(forKey key: String) -> Any? {
        guard let store = store else { return nil }
        if let value = store.object(forKey: key) { return value }
        for (alias, target) in preferenceKeyAliases where target == key {
            if let value = store.object(forKey: alias) {
                warnOnce(alias, "Preference key \(alias) is misspelled; using it as \(key). Please rename it to \(key).")
                return value
            }
        }
        return nil
    }

    /// Where a single key's value comes from, for -showConfig.
    func origin(ofKey key: String) -> String {
        guard let store = store, rawValue(forKey: key) != nil else { return "default" }
        return store.objectIsForced(forKey: key) ? "managed" : "set"
    }

    func warnOnce(_ id: String, _ message: String) {
        if warned.insert(id).inserted {
            laps_log.print(message, .warn)
        }
    }
}

// MARK: - Type coercion

private func coerceInt(_ raw: Any) -> Int? {
    if let n = raw as? NSNumber { return n.intValue }
    if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

private func coerceBool(_ raw: Any) -> Bool? {
    if let n = raw as? NSNumber { return n.boolValue }
    if let s = raw as? String {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
    return nil
}

private func coerceString(_ raw: Any) -> String? {
    if let s = raw as? String { return s }
    if let n = raw as? NSNumber { return n.stringValue }
    return nil
}

private func coerceStringArray(_ raw: Any) -> [String]? {
    if let a = raw as? [Any] { return a.compactMap { coerceString($0) } }
    if let s = raw as? String { return s.isEmpty ? [] : [s] }
    return nil
}

private func coerceRequirements(_ raw: Any) -> [String : Int]? {
    guard let dict = raw as? [String : Any] else { return nil }
    var result = defaultpreferences["PasswordRequirements"] as! [String : Int]
    for (key, value) in dict {
        guard let canonical = requirementKeyAliases[key.lowercased()] else {
            PreferenceStore.shared.warnOnce("req-\(key)", "Unknown PasswordRequirements key \(key) ignored. Valid keys: Uppercase, Lowercase, Number, Symbol.")
            continue
        }
        guard let count = coerceInt(value), count >= 0 else {
            PreferenceStore.shared.warnOnce("req-\(key)-value", "PasswordRequirements \(key) is not a non-negative number; using 0.")
            continue
        }
        result[canonical] = count
    }
    return result
}

private func normalizeMethod(_ value: String) -> String {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "ad", "activedirectory", "active directory": return "AD"
    case "local": return "Local"
    default: return value   // main.swift rejects unknown methods with an error
    }
}

/// Pull a configuration setting from the chosen preference domain or fall back to the default.
/// The returned value always has the same type as the key's default, so callers' casts are safe.
func GetPreference(preference_key key: String) -> Any? {
    let fallback = defaultpreferences[key]
    guard let raw = PreferenceStore.shared.rawValue(forKey: key) else { return fallback }
    guard let fallback = fallback else { return raw }

    // Match on the default's exact type (not `is`, which can bridge numbers and booleans).
    let expected = type(of: fallback)
    var coerced : Any?
    if expected == Bool.self                  { coerced = coerceBool(raw) }
    else if expected == Int.self              { coerced = coerceInt(raw) }
    else if expected == String.self           { coerced = coerceString(raw) }
    else if expected == [String].self         { coerced = coerceStringArray(raw) }
    else if expected == [String : Int].self   { coerced = coerceRequirements(raw) }
    else                                      { coerced = raw }
    guard var value = coerced else {
        let shown = secretPreferenceKeys.contains(key) ? "(redacted)" : "\(fallback)"
        PreferenceStore.shared.warnOnce("type-\(key)", "Preference \(key) has an unexpected type (\(type(of: raw))). Using the default value \(shown).")
        return fallback
    }
    if key == "Method", let method = value as? String {
        value = normalizeMethod(method)
    }
    return value
}

/// Prints the effective configuration for -showConfig. FirstPass is never printed.
func printEffectiveConfiguration() {
    let prefs = PreferenceStore.shared
    print("macOSLAPS effective configuration")
    print("  Domain: \(prefs.domain)")
    print("  Source: \(prefs.source.rawValue)")
    for key in defaultpreferences.keys.sorted() {
        let value = GetPreference(preference_key: key)
        var shown = value.map { "\($0)" } ?? "nil"
        if secretPreferenceKeys.contains(key) {
            shown = ((value as? String) ?? "").isEmpty ? "(not set)" : "(set, redacted)"
        }
        print("  \(key) = \(shown)  [\(prefs.origin(ofKey: key))]")
    }
}

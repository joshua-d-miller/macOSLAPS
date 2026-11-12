/*
===============================================================================
 macOSLAPS | Preferences | Preferences.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2017-06-13
 Updated:   2026-11-12

 Purpose:
     Reads the settings. macOSLAPS is moving from the original
     edu.psu.macoslaps domain to com.joshua-d-miller.macoslaps; both are
     read so existing deployments keep working. The new domain wins per
     key and the legacy one fills only keys the new one doesn't set;
     managed (configuration profile) values come before
     /Library/Preferences, then the built-in defaults. Values are coerced
     to the expected type, so one written with the wrong type is converted
     or replaced by the default with a warning instead of crashing (#86).
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    New domain com.joshua-d-miller.macoslaps, per
                        claude    key over the legacy one; type coercion;
                                  -showconfig; ApprovedAdmins, AdminGroupPolicy
                                  and the reveal settings; reads the domains
                                  through CFPreferences.

                                  New header and section style.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------ //
// | Domains and defaults | //
// ------------------------ //
// The two domains and every key's default.                                  //
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
    "ADSchema"               :       "legacy",
    "PasswordStyle"          :       "random",
    "InventoryHook"          :       "",
    "InventoryHookCommand"   :       [String](),
    "InventoryHookConfirms"  :       false,
    "StagedRotation"         :       "auto",
    "EscrowConfirmations"    :       2,
    "EscrowCertificates"     :       [Any](),
    "ApprovedAdmins"         :       [String](),
    "AdminGroupPolicy"       :       "auto",
    "RetrievalMode"          :       "escrow",
    "RevealGracePeriod"      :       4,
    "RevealAction"           :       "rotateAndLogout",
    "ADRevealCode"           :       false,
    "PasswordRequirements"   :       [
        "Uppercase"          :       0,
        "Lowercase"          :       0,
        "Number"             :       0,
        "Symbol"             :       0
        ],
    ]

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------------- //
// | Aliases and secrets | //
// ----------------------- //
// Older key spellings, and keys never printed.                              //
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

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------------------- //
// | Where a value came from | //
// --------------------------- //
// Managed or local, new or legacy domain, or the default.                   //
enum PreferenceSource: String {
    case managedNew      = "configuration profile (new domain)"
    case managedLegacy   = "configuration profile (legacy edu.psu.macoslaps domain)"
    case unmanagedNew    = "/Library/Preferences (new domain)"
    case unmanagedLegacy = "/Library/Preferences (legacy edu.psu.macoslaps domain)"
    case defaults        = "built-in defaults"
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------ //
// | Reading the settings | //
// ------------------------ //
// Merges both domains per key and remembers notices for the log.            //
/// Settings are resolved one key at a time, in this order:
///   1. new domain, configuration profile (managed)
///   2. legacy edu.psu.macoslaps domain, configuration profile
///   3. new domain, /Library/Preferences
///   4. legacy domain, /Library/Preferences
///   5. built-in default
/// So anything set in the new domain wins, and the legacy domain only fills in keys the
/// new one doesn't set. Admins can move one key at a time; -showConfig shows where each
/// key came from.
/// One preference domain read through CFPreferences. UserDefaults(suiteName:) won't
/// open a suite named like the app's own bundle identifier, which
/// com.joshua-d-miller.macoslaps now is; CFPreferences reads any domain the same way.
struct PreferenceDomain {
    let id : CFString
    init(_ domain: String) { id = domain as CFString }
    func object(forKey key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, id) as Any?
    }
    func objectIsForced(forKey key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, id)
    }
}

final class PreferenceStore {
    static let shared = PreferenceStore()

    private struct Layer {
        let store : PreferenceDomain
        let domain : String
        let managed : Bool
        let source : PreferenceSource
    }
    private let layers : [Layer]
    /// The most authoritative layer that supplies at least one setting.
    let source : PreferenceSource
    /// The domain admins should look at: the new one if it supplies anything, else legacy.
    let domain : String
    private var warned = Set<String>()

    private init() {
        var list : [Layer] = []
        let n = PreferenceDomain(preferenceDomain)
        let l = PreferenceDomain(legacyPreferenceDomain)
        list.append(Layer(store: n, domain: preferenceDomain, managed: true, source: .managedNew))
        list.append(Layer(store: l, domain: legacyPreferenceDomain, managed: true, source: .managedLegacy))
        list.append(Layer(store: n, domain: preferenceDomain, managed: false, source: .unmanagedNew))
        list.append(Layer(store: l, domain: legacyPreferenceDomain, managed: false, source: .unmanagedLegacy))
        layers = list

        let knownKeys = Array(defaultpreferences.keys) + Array(preferenceKeyAliases.keys)
        func supplies(_ layer: Layer) -> Bool {
            knownKeys.contains { layer.store.object(forKey: $0) != nil && layer.store.objectIsForced(forKey: $0) == layer.managed }
        }
        let active = list.filter(supplies)
        source = active.first?.source ?? .defaults
        domain = active.contains { $0.domain == preferenceDomain } || active.isEmpty ? preferenceDomain : legacyPreferenceDomain

        // Notices are collected, not printed here: this initializer can run during any
        // command, and printing would corrupt machine-read output such as -version.
        let legacyKeys = defaultpreferences.keys.sorted().filter { lookup($0)?.layer.domain == legacyPreferenceDomain }
        let newUsed = active.contains { $0.domain == preferenceDomain }
        if !legacyKeys.isEmpty && newUsed {
            notices.append("Settings come from both \(preferenceDomain) and \(legacyPreferenceDomain). Keys set in \(preferenceDomain) take precedence; these still come from the legacy domain: \(legacyKeys.joined(separator: ", ")).")
        } else if !legacyKeys.isEmpty {
            notices.append("Settings are being read from the legacy domain \(legacyPreferenceDomain). This still works, but please move your configuration to \(preferenceDomain) (same keys, new PayloadType). Legacy support will be removed in a future major release.")
        }
        if active.isEmpty {
            notices.append("No macOSLAPS settings found in \(preferenceDomain) or \(legacyPreferenceDomain). Using built-in defaults.")
        }
    }

    /// First layer that has a value for `key` (or a known misspelling of it).
    private func lookup(_ key: String) -> (value: Any, layer: Layer, alias: String?)? {
        let aliases = preferenceKeyAliases.filter { $0.value == key }.map { $0.key }
        for layer in layers {
            for name in [key] + aliases {
                if let value = layer.store.object(forKey: name), layer.store.objectIsForced(forKey: name) == layer.managed {
                    return (value, layer, name == key ? nil : name)
                }
            }
        }
        return nil
    }

    /// Configuration notices (legacy domain, mixed domains, no settings).
    private(set) var notices : [String] = []
    private var noticesEmitted = false

    /// Logs the notices once. Called when a rotation happens and by -showConfig / -status -v,
    /// so routine runs every 90 minutes don't repeat them.
    func emitNotices() {
        guard !noticesEmitted else { return }
        noticesEmitted = true
        for notice in notices { laps_log.print(notice, .warn) }
    }

    /// Raw value for a key, resolved across the layers above.
    func rawValue(forKey key: String) -> Any? {
        guard let found = lookup(key) else { return nil }
        if let alias = found.alias {
            warnOnce(alias, "Preference key \(alias) is misspelled; using it as \(key). Please rename it to \(key).")
        }
        return found.value
    }

    /// Where a single key's value comes from, for -showConfig.
    func origin(ofKey key: String) -> String {
        guard let found = lookup(key) else { return "default" }
        let place = found.layer.domain == preferenceDomain ? "new domain" : "legacy domain"
        return (found.layer.managed ? "profile, " : "/Library/Preferences, ") + place
    }

    func warnOnce(_ id: String, _ message: String) {
        if warned.insert(id).inserted {
            laps_log.print(message, .warn)
        }
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ----------------- //
// | Type coercion | //
// ----------------- //
// Turns a value of the wrong type into the right one, or nil.               //

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

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------ //
// | Looking up a setting | //
// ------------------------ //
// The function the rest of macOSLAPS calls.                                 //
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

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------- //
// | -showconfig | //
// --------------- //
// Every setting, where it came from, and whether it is managed. Never       //
// FirstPass.                                                                //
/// Prints the effective configuration for -showConfig. FirstPass is never printed.
func printEffectiveConfiguration() {
    let prefs = PreferenceStore.shared
    prefs.emitNotices()
    print("macOSLAPS effective configuration")
    print("  Domain: \(prefs.domain)")
    print("  Source: \(prefs.source.rawValue)")
    for key in defaultpreferences.keys.sorted() {
        let value = GetPreference(preference_key: key)
        var shown = value.map { "\($0)" } ?? "nil"
        if secretPreferenceKeys.contains(key) {
            shown = ((value as? String) ?? "").isEmpty ? "(not set)" : "(set, redacted)"
        }
        if key == "EscrowCertificates" {
            let config = Escrow.certificateConfig()
            shown = config.configured
                ? "\(config.certificates.count) usable certificate(s)" + (config.problems.isEmpty ? "" : "; " + config.problems.joined(separator: "; "))
                : "(not set: plaintext escrow)"
        }
        print("  \(key) = \(shown)  [\(prefs.origin(ofKey: key))]")
    }
}

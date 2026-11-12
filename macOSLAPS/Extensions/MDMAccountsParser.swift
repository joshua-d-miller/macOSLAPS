/*
===============================================================================
 macOSLAPS | Extensions | MDMAccountsParser.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-12
 Updated:   2026-11-12

 Purpose:
     Reads the AutoSetupAdminAccounts list (the admin accounts an MDM had
     Setup Assistant create during Automated Device Enrollment: GUID and
     short name) from the output of mdmclient QueryDeviceInformation, and
     the enrollment state from profiles status. No other dependencies, so
     CI tests it on its own (Tests/MDMAccountsTests).
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    New file.
                        claude
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ---------------------------- //
// | Parsing mdmclient output | //
// ---------------------------- //
// The text after "Daemon response:" is an old-style property list. If it    //
// won't parse whole, only the AutoSetupAdminAccounts array is parsed.       //
struct AutoSetupAdmin: Equatable {
    let guid: String
    let shortName: String
}

enum MDMAccountsParser {
    /// The AutoSetupAdminAccounts entries, [] when the list is empty, or nil when the
    /// output doesn't contain a list that can be read with confidence.
    static func parse(_ raw: String) -> [AutoSetupAdmin]? {
        // Output pasted through Mail or Slack gains curly quotes; mdmclient prints straight ones.
        let output = raw.replacingOccurrences(of: "\u{201C}", with: "\"")
                        .replacingOccurrences(of: "\u{201D}", with: "\"")
        if let start = output.range(of: "Daemon response:"),
           let dict = plist(String(output[start.upperBound...])) as? [String: Any],
           let responses = dict["QueryResponses"] as? [String: Any] {
            guard let list = responses["AutoSetupAdminAccounts"] else { return nil }
            return entries(list)
        }
        guard let array = arrayText(after: "AutoSetupAdminAccounts", in: output),
              let value = plist(array) else { return nil }
        return entries(value)
    }

    private static func plist(_ text: String) -> Any? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    /// Every entry needs a GUID and a short name; anything else makes the whole list unreadable.
    private static func entries(_ value: Any) -> [AutoSetupAdmin]? {
        guard let items = value as? [Any] else { return nil }
        var result : [AutoSetupAdmin] = []
        for item in items {
            guard let d = item as? [String: Any] else { return nil }
            var lower : [String: Any] = [:]
            for (k, v) in d { lower[k.lowercased()] = v }
            guard let guid = lower["guid"] as? String, let name = lower["shortname"] as? String,
                  !guid.isEmpty, !name.isEmpty else { return nil }
            result.append(AutoSetupAdmin(guid: guid, shortName: name))
        }
        return result
    }

    /// "Key = ( ... );" -> "( ... )", ignoring parentheses inside quoted strings.
    private static func arrayText(after key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: key) else { return nil }
        let rest = text[keyRange.upperBound...]
        guard let eq = rest.firstIndex(of: "=") else { return nil }
        let afterEq = rest[rest.index(after: eq)...]
        guard let open = afterEq.firstIndex(where: { !$0.isWhitespace }), afterEq[open] == "(" else { return nil }
        var depth = 0
        var inQuote = false
        var escaped = false
        var i = open
        while i < afterEq.endIndex {
            let c = afterEq[i]
            if inQuote {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inQuote = false }
            } else if c == "\"" {
                inQuote = true
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return String(afterEq[open...i]) }
            }
            i = afterEq.index(after: i)
        }
        return nil
    }
}

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// -------------- //
// | Enrollment | //
// -------------- //
// Whether this Mac is enrolled in an MDM, from profiles status.             //
enum MDMEnrollment {
    /// true / false from "MDM enrollment: Yes|No"; nil when it can't be told.
    static func parse(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard t.hasPrefix("mdm enrollment:") else { continue }
            let v = t.dropFirst("mdm enrollment:".count).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("yes") { return true }
            if v.hasPrefix("no") { return false }
        }
        return nil
    }
}


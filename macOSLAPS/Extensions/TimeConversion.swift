/*
===============================================================================
 macOSLAPS | Extensions | TimeConversion.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller
 Created:   2017-06-13
 Updated:   2026-11-17

 Purpose:
     Converts between Windows file time (Active Directory's password
     expiration) and dates.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-17   joshua    TimeConversion.expired; a value that isn't a
                        claude    number no longer crashes.
 4.0.0     2026-11-11   claude    New header and section style.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// ------------------------- //
// | Windows and Unix time | //
// ------------------------- //
// AD stores 100-nanosecond intervals since 1601.                            //
class TimeConversion: NSObject {
    /// 2001-01-01: an expiration time that is always in the past, so the next run rotates.
    static let expired = "126227988000000000"

    /// A Windows time from AD as a date; nil when the value isn't a number.
    class func epoch(exp_time: String) -> Date? {
        guard let windows = Int64(exp_time.trimmingCharacters(in: .whitespaces)), windows >= 0 else { return nil }
        return Date(timeIntervalSince1970: Double(windows / 10_000_000 - 11_644_473_600))
    }
    /// The Windows time DaysTillExpiration from now, for AD's expiration attribute.
    class func windows() -> String {
        let expires = Calendar.current.date(byAdding: .day, value: Constants.days_till_expiration, to: Date())
            ?? Date().addingTimeInterval(TimeInterval(Constants.days_till_expiration) * 86400)
        return String((Int64(expires.timeIntervalSince1970) + 11_644_473_600) * 10_000_000)
    }
}


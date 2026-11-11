/*
===============================================================================
 macOSLAPS | Extensions | DateFormatter.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller
 Created:   2017-06-13
 Updated:   2026-11-11

 Purpose:
     The date format macOSLAPS uses in the keychain comment and the log:
     yyyy-MM-dd HH:mm:ss in the Mac's time zone.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-11   claude    New header and section style.
===============================================================================
*/

import Foundation

// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: //
// --------------- //
// | Date format | //
// --------------- //
// One formatter shared by the whole run.                                    //
// Used to format the date when needed
func date_formatter () -> ISO8601DateFormatter {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.timeZone = TimeZone.current
    dateFormatter.formatOptions = [
        .withFullDate,
        .withTime,
        .withSpaceBetweenDateAndTime,
        .withDashSeparatorInDate,
        .withColonSeparatorInTime]
    return(dateFormatter)
}

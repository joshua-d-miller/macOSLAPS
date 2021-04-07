///
///  DateFormatter.swift
///  macOSLAPS-repair
///
///  Created by Joshua D. Miller on 6/13/17.
///  The Pennsylvania State University
///

import Foundation


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

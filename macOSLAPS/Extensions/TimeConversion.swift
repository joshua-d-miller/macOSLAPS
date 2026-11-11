/*
===============================================================================
 macOSLAPS | Extensions | TimeConversion.swift
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller
 Created:   2017-06-13
 Updated:   2026-11-11

 Purpose:
     Converts between Windows file time (Active Directory's password
     expiration) and dates.
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
// ------------------------- //
// | Windows and Unix time | //
// ------------------------- //
// AD stores 100-nanosecond intervals since 1601.                            //
class TimeConversion: NSObject {
    // Windows to Epoch time converter and vice versa
    class func epoch(exp_time: String) -> Date? {
        let converted_time = Double((Int(exp_time)! / 10000000 - 11644473600))
        let pw_expires_date = Date(timeIntervalSince1970: converted_time)
        return(pw_expires_date)
    }
    class func windows() -> String? {
        let new_expiration_time = Calendar.current.date(byAdding: .day, value: Constants.days_till_expiration, to: Date())!
        let new_conv_time = Int(new_expiration_time.timeIntervalSince1970)
        let new_ad_expiration_time = String((new_conv_time + 11644473600) * 10000000)
        return(new_ad_expiration_time)
    }
}


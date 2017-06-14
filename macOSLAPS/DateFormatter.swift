//
//  DateFormatter.swift
//  macOSLAPS
//
//  Created by Joshua D. Miller on 6/13/17.
//  The Pennsylvania State University
//

import Foundation


// Used to format the date when needed
func date_formatter () -> DateFormatter {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "E MMM dd, yyyy hh:mm:ss a"
    return(dateFormatter)
}

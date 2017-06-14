//
//  Extensions.swift
//  macOSLAPS
//
//  Created by Joshua D. Miller on 6/13/17.
//  The Pennsylvania State University
//

import Foundation

// Extension to randomly pull from an Array
// From Stack Overflow https://stackoverflow.com/questions/24003191/pick-a-random-element-from-an-array
extension Array {
    func randomItem() -> Element {
        let index = Int(arc4random_uniform(UInt32(self.count)))
        return self[index]
    }
}

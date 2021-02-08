//
//  main.swift
//  macOSLAPS-repair
//
//  Created by Miller, Joshua D. on 2/5/21.
//  Copyright © 2021 Joshua D. Miller. All rights reserved.
//

import Foundation

func repair_ACLS() {
    // Save Password by creating new app signature
    let fix_keychain_status: OSStatus = KeychainService.updatePerm()
    if fix_keychain_status == 0 {
        exit(0)
    } else {
        exit(1)
    }
    
}

repair_ACLS()

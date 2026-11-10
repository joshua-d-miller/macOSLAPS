///
///  secureToken.swift
///  macOSLAPS
///
///  Created by Joshua D. Miller on 2/21/21.
///
///  Last updated November 10, 2026
///
///  Fails closed: the account only counts as having no secureToken when
///  sysadminctl runs successfully and says DISABLED. An error, a timeout or
///  unexpected output is "unknown", which rotation treats like a token (the old
///  password is required), so a token is never removed by mistake.

import Foundation

enum SecureTokenStatus: String {
    case enabled, disabled, unknown
}

func secureTokenStatus(for account: String = Constants.local_admin) -> SecureTokenStatus {
    // Test-only switches used by CI, where test accounts can't get a real token.
    // MACOSLAPS_TEST_ASSUME_SECURETOKEN=1 -> enabled; MACOSLAPS_TEST_SECURETOKEN=unknown|enabled
    let env = ProcessInfo.processInfo.environment
    if env["MACOSLAPS_TEST_ASSUME_SECURETOKEN"] == "1" { return .enabled }
    if let forced = env["MACOSLAPS_TEST_SECURETOKEN"].flatMap(SecureTokenStatus.init(rawValue:)), forced != .disabled {
        return forced
    }

    let result = Shell.execute(launchPath: "/usr/sbin/sysadminctl", arguments: ["-secureTokenStatus", account], timeout: 30)
    guard !result.timedOut, result.status == 0 else { return .unknown }
    // sysadminctl prints e.g. "Secure token is ENABLED for user admin".
    let upper = result.output.uppercased()
    if upper.contains("IS ENABLED") { return .enabled }
    if upper.contains("IS DISABLED") { return .disabled }
    return .unknown
}

/// Kept for existing callers: true unless the account is confirmed to have no secureToken.
func Determine_secureToken() -> Bool {
    let status = secureTokenStatus()
    switch status {
    case .enabled:
        laps_log.print("The local admin: \(Constants.local_admin) has a secureToken. Performing secure password change...", .info)
    case .unknown:
        laps_log.print("Could not determine whether \(Constants.local_admin) has a secureToken. Treating it as if it does (the current password is required).", .warn)
    case .disabled:
        break
    }
    return status != .disabled
}

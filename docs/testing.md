# Testing 4.0

macOSLAPS 4.0 is a prerelease. Every build is tested automatically, but some things need real Macs, a real MDM or a real domain. This page lists both, so you can see what's covered and pick something to try.

## How to report

Post in **#laps** on [MacAdmins Slack](https://macadmins.org) or open a [GitHub issue](https://github.com/joshua-d-miller/macOSLAPS/issues/new/choose) (there's a template). Include:

- your macOS version, and Intel or Apple silicon;
- your MDM, `Method` and `RetrievalMode`;
- the output of `sudo macOSLAPS -status -v` and `sudo macOSLAPS -showConfig` (neither prints a password);
- the relevant part of `/Library/Logs/macOSLAPS.log`.

Test on non-production Macs first, and read [Upgrading from 3.x](upgrading.md) before installing over an earlier version.

## Please test

These need real hardware, a real directory or a real MDM, which CI doesn't have. Tell us your macOS version (13 through 27), Intel or Apple silicon, your MDM, your Method, and your RetrievalMode.

1. **secureToken accounts, especially on macOS 26 (#120, #96).** CI can't create a real secureToken. Test the first rotation with FirstPass, a later rotation, then logging in and **unlocking FileVault** with the new password.
2. **Admin group protection on your fleet.** Set `ApprovedAdmins` the way you would in production, then compare `-status -v` with what you expect.
    - Does `-status` list your MDM's enrollment admin under `mdmAdmins` (Jamf PreStage admin, Intune ADE admin, Iru Auto Admin)? If not, please send the `AutoSetupAdminAccounts` block from `sudo /usr/libexec/mdmclient QueryDeviceInformation`.
    - Is the Jamf management account listed as unapproved? (Expected until you add it to `ApprovedAdmins`.)
    - Is your elevation tool detected?
3. **Migration on real Macs** from 3.0.4, 4.0.0 (845) and older 3.x builds, including AD-mode Macs and Macs with a staged pending password.
4. **Device mode end to end:** the MDM collects the code, a standard user reveals the password in the app, elevation, the menu bar countdown, the 15-minute notification, and the forced logout and rotation at the deadline, with and without the admin signed in.
5. **The app:** VoiceOver, the phonetic spelling over the phone, the icon in the Dock and notifications, and the menu bar item's menu (CI shows the countdown but can't open the menu).
6. **Encrypted escrow in your MDM:** does the inventory attribute keep the whole CMS block with its line breaks? Smart card or YubiKey decryption with `security cms`.
7. **Active Directory on a real domain** with each `ADSchema`, and `ADRevealCode` in device mode.
8. **Settings delivered as configuration profiles**, split across both domains (CI can only test files in /Library/Preferences), and the profile manifests imported into Jamf Pro or iMazing Profile Editor.
9. **Your packages and InstallerChoices.xml,** including the `-Binary-` pkg alone over 845, and the Login Items notification text and your Managed Login Items rule (#75).
10. **Staged rotation with your MDM's hook,** including `InventoryHookConfirms` with your MDM's agent command.
11. **Uninstall:** `-uninstall`, then `-uninstall -purge`. Is anything left behind?
12. **macOS 13 and 14,** which have no CI runners.

## Tested on every build

Every build runs these on GitHub's macOS runners. A build can only be published when all of them pass.

### Smoke test on macOS 15 and 26 (Apple silicon and Intel) and 27, about 205 checks each

- Install layout: the app, the symlink, `/etc/paths.d/laps`, both LaunchDaemons, the LaunchAgent, receipts, the app icon and strings; Login Items attributed to macOSLAPS.app.
- Rotation: first rotation with FirstPass, forced rotation, 25 rotations through the password generator, the old password stops working.
- Safety: a simulated secureToken account requires the old password; secureToken detection fails closed; stop signals mid-change are ignored; two runs at once don't interleave; an outside password change stops rotation without touching the account; `-firstPass` and `-firstPass -`.
- Settings: new and old domains resolved per key.
- `-status`, `-status -v`, `-escrow` in plain text and CMS, `-initialize`, staged rotation, the custom inventory hook, `PasswordStyle readable`.
- Device mode: reveal codes, wrong codes, the five-try lockout, the grace deadline, `-expireIn`, the deadline met between scheduled runs, codes refused on the command line.
- The privileged service: a standard user reveals through XPC, an unsigned copy is refused, rotate-now requests (including stale ones, which are ignored).
- Admin group protection: unapproved admins removed, approved ones and groups kept, report mode, MDM-created admin list read.
- Logs: location, symlink, rotation, unified log.
- `-uninstall` keeps the password; `uninstall.sh --purge` removes everything.

### Upgrade from 4.0.0 (845) on macOS 15, 26 (Apple silicon and Intel) and 27, about 58 checks each

- 845 installed and rotated, then this build installed over it.
- The password migrated from 845's keychain item with its creation date; the old item and export deleted; old LaunchDaemon and receipts removed.
- "Migration required" and recovery with `-firstPass -initialize`; 3.x plaintext files never used.
- Admins' existing scripts and the Jamf extension attributes still work, including with a password full of shell and JSON special characters.
- The `-Binary-` and `-LD-` packages.
- The old log kept as `macOSLAPS-3x.log`.

### Upgrade from 3.0.4 on macOS 15, 26 (Apple silicon and Intel) and 27

- 3.0.4 installed and rotated, then this build installed over it.
- The password migrated from 3.0.4's keychain item; plaintext files, LaunchDaemon and receipts removed; rotation works afterwards and invalidates 3.0.4's password.

### The window and menu bar, driven like a technician would on macOS 26 and 27

- The app opened as the signed-in standard user; the code and a ticket number typed into the window through Accessibility; **Reveal Password** pressed.
- The reveal recorded with the user and the ticket, and the grace period started; **Show Phonetic** pressed.
- The menu bar countdown appeared; the icon checked in Finder; the escrow-mode window; a reveal from Terminal through a pipe.
- Every step is captured as a screenshot (the ones on these pages come from this test).

### Also on every build

- About 23,000 password-generator checks, including 10,000 random policies.
- Unit tests for the shell helper and for reading the MDM-created admin list (including real output from a Mac with a Jamf PreStage admin).
- The CMS escrow from the smoke test decrypted on Windows with `Unprotect-CmsMessage` in PowerShell 7 and Windows PowerShell 5.1.
- Signing and notarization of the app and all three pkgs; style checks; every setting present in the profile manifests.

## Known issues and limitations

- **#120 is still open,** and **#96** is unconfirmed: "Unable to change password using FirstPass" on secureToken accounts. See test 1.
- **The Jamf management account** (user-initiated enrollment) is not detected: macOS has no record of it. List it in `ApprovedAdmins`. MDM-created admins from Automated Device Enrollment are detected.
- **Reveals happen after login.** Device mode can't reveal the password at the FileVault unlock screen or the login window. Escrow the FileVault recovery key.
- **A promoted admin is caught on the next run** (every 90 minutes), not the moment it happens.
- **The window is English only.** The strings are in `Resources/en.lproj/Localizable.strings` for translators.
- **`ADSchema windowsLAPS` and `both` are experimental.** CI has not run macOSLAPS in AD mode against a domain.
- **Windows LAPS encrypted passwords** (`msLAPS-EncryptedPassword`) are not supported.
- **Entra ID** has no supported way for non-Windows devices to store LAPS passwords. With Intune, use custom attributes with `-escrow` (ideally encrypted), or device mode.
- **`PasswordStyle passphrase`** falls back to `readable` for now.
- **`-getPassword`** is deprecated and will be removed in 5.0. Use `-escrow`.
- **The 3.0.4 and 4.0.0 (845) pkgs were re-signed** on Nov 14, 2026, ahead of Apple retiring the old signing authority on Feb 1, 2027. Their contents are unchanged and they're notarized, but their SHA-256 checksums changed.

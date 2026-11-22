# Command line

The installer puts `macOSLAPS` on the `PATH` (`/etc/paths.d/laps` points into the app), so these work from any shell. Most need `sudo`; `-reveal`, `-rotateNow`, `-status`, `-version` and `-help` also work without it.

| Command | What it does |
|---|---|
| `macOSLAPS` | A normal run: rotates if the password is due, checks the admin group. The LaunchDaemon runs this every 90 minutes. |
| `-rotate` | Rotates now, whatever the expiration date. `-resetPassword` is the older name and still works. |
| `-rotate -currentPassword -` | Rotates when macOSLAPS doesn't know the account's current password, reading it from a prompt or a pipe so it never shows in the process list: `printf '%s\n' "$pw" \| macOSLAPS -rotate -currentPassword -`. Without a value the `FirstPass` key is used. Needed for a secureToken account's first rotation. `-firstPass` is the older name and still works. |
| `-rotate -newPassword -` | Sets a password you choose instead of a generated one, read from a prompt or a pipe (never the command line). It must meet the password settings (`PasswordLength`, `PasswordRequirements`, `RemovePassChars`, `ExclusionSets`, `PasswordStyle`) and is staged and escrowed like a generated one. With `-currentPassword -` too, pipe the two passwords on separate lines, in the order of the options. **Off unless your MDM's profile sets `AllowNewPassword`** (see [below](#plaintext-commands-are-opt-in)). |
| `-initialize` | With `-currentPassword`: checks the password and stores it **without** rotating. The first rotation happens after `DaysTillExpiration`. |
| `-escrow` | Prints the password for an MDM inventory attribute: JSON, a CMS block when `EscrowCertificates` is set, or the reveal code in device mode. See [Escrow](retrieval/escrow.md). |
| `-read` | Prints only the current password, for scripts on the Mac (XCreds, a macOS installer). Unlike `-escrow` it never counts as the MDM collecting a staged password, and it prints even with `EscrowCertificates` set, since it stays on the Mac. Refused in device mode. **Off unless your MDM's profile sets `AllowRead`** (see [below](#plaintext-commands-are-opt-in)). |
| `-status` | One line of JSON about the account, secureToken, FileVault, the stored password, escrow, admins and the last run. See [below](#status-fields). |
| `-status -v` | The same as a readable checklist, with what to do about each problem. |
| `-reveal` | Device mode: asks for the reveal code (or reads it from a pipe), shows the password and starts the grace period. Add `-reason "<ticket>"` to record why. The code is never accepted on the command line. |
| `-expireIn <time>` | The password changes after `<time>`: `4h`, `30m`, `2h30m`, or `0` for the next run. Use it after handing the password out. |
| `-rotateNow` | Ends an active reveal or `-expireIn` grace period now. Any user can run it; the menu bar's **Done — Rotate Now** uses it. |
| `-showConfig` | The settings in effect, which preference domain each came from, and whether it's managed, set locally or a default. `FirstPass` is never printed. |
| `-uninstall` | Removes the app, LaunchDaemons, LaunchAgent, symlink and receipts. The stored password is kept, so a reinstall carries on. |
| `-uninstall -purge` | Also deletes the stored passwords, the state and the logs. Make sure your MDM has the password first. |
| `-getPassword` | **Deprecated, removed in 5.0.** Copies the password to a temporary keychain item for 3.x scripts. Use `-escrow` for the MDM and `-read` for scripts on the Mac. |
| `-version` | Prints the version, `4.0.0.<build>`. |
| `-help` | Lists the commands. |

The uninstall script is also in the app, for MDMs that run scripts: `/Applications/macOSLAPS.app/Contents/Resources/uninstall.sh [--purge]`.

## Plaintext commands are opt-in

`-read` hands the password to anything running as root on the Mac, in plaintext. `-newPassword` lets it choose the password. Root can already reset the account with `dscl` or `sysadminctl`, but that breaks its secureToken. With these two commands it gets a working password and the secureToken stays intact. So both are off until you turn them on:

- `AllowRead true` allows `-read`; `AllowNewPassword true` allows `-newPassword`.
- They count **only from a configuration profile** your MDM installs. A value in `/Library/Preferences` is ignored (root can write there), and macOSLAPS logs that it ignored it.
- Setting them is your acknowledgement of that risk. Where you can, retrieve the password through [`EscrowCertificates`](retrieval/encrypted-escrow.md) or [device mode](retrieval/device-mode.md) instead.
- When a command is off, it exits with code 78 and names the key to set.

## Status fields

| Field | Meaning |
|---|---|
| `version`, `osVersion` | macOSLAPS and macOS versions |
| `method`, `adSchema`, `retrievalMode` | How the password is kept |
| `account`, `accountExists`, `accountIsAdmin`, `accountHidden` | The managed admin |
| `secureToken`, `fileVault`, `recoveryKeyEscrowProfile`, `bootstrapTokenEscrowed` | FileVault readiness |
| `passwordStored`, `passwordVerifies`, `passwordIsFirstPass` | Whether macOSLAPS holds a working password, and whether it's still the shared `FirstPass` one |
| `lastRotation`, `expires` | When it last changed and when it's due |
| `escrow`, `escrowCertificates`, `escrowCertificatesExpire`, `inventoryHook` | Escrow setup |
| `stagedRotation`, `pending`, `pendingSince`, `pendingExports`, `pendingExportsNeeded` | [Staged rotation](retrieval/escrow.md#staged-rotation) |
| `lastRun`, `lastResult`, `lastMessage`, `lastSuccess` | The last run |
| `settingsDomain`, `settingsSource` | Where the settings came from |
| `migration`, `migratedAt`, `migratedFrom` | [Migration](upgrading.md) from 3.x / 845 |
| `adminGroupPolicy`, `unapprovedAdmins`, `elevationTool`, `demotedAdmins` | [Admin group protection](admin-group.md) |
| `mdmAdmins`, `mdmAdminList`, `localAdminIsMDMAccount` | [MDM-created admins](admin-group.md#mdm-created-admins) |
| `externalChange`, `externalChangeReason` | The password was [changed by something else](secure-token.md#when-something-else-changes-the-password) |
| `revealCodeSet`, `revealFailures`, `revealLocked`, `revealRetryAt`, `revealCodeCollected`, `revealedAt`, `rotatesAt`, `rotateReason` | [Device mode](retrieval/device-mode.md) and `-expireIn` |

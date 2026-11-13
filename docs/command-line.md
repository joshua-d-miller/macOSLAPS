# Command line

The installer puts `macOSLAPS` on the `PATH` (`/etc/paths.d/laps` points into the app), so these work from any shell. Most need `sudo`; `-reveal`, `-rotateNow`, `-status`, `-version` and `-help` also work without it.

| Command | What it does |
|---|---|
| `macOSLAPS` | A normal run: rotates if the password is due, checks the admin group. The LaunchDaemon runs this every 90 minutes. |
| `-resetPassword` | Rotates now, whatever the expiration date. |
| `-firstPass <password>` | Rotates using this as the current password (or the `FirstPass` key if no password follows). Needed for a secureToken account's first rotation. |
| `-firstPass -` | The same, reading the password from a prompt or a pipe, so it never shows in the process list: `printf '%s\n' "$pw" \| macOSLAPS -firstPass - -resetPassword` |
| `-initialize` | With `-firstPass`: checks the password and stores it **without** rotating. The first rotation happens after `DaysTillExpiration`. |
| `-escrow` | Prints the password for an MDM inventory attribute: JSON, a CMS block when `EscrowCertificates` is set, or the reveal code in device mode. See [Escrow](retrieval/escrow.md). |
| `-status` | One line of JSON about the account, secureToken, FileVault, the stored password, escrow, admins and the last run. See [below](#status-fields). |
| `-status -v` | The same as a readable checklist, with what to do about each problem. |
| `-reveal` | Device mode: asks for the reveal code (or reads it from a pipe), shows the password and starts the grace period. Add `-reason "<ticket>"` to record why. The code is never accepted on the command line. |
| `-expireIn <time>` | The password changes after `<time>`: `4h`, `30m`, `2h30m`, or `0` for the next run. Use it after handing the password out. |
| `-rotateNow` | Ends an active reveal or `-expireIn` grace period now. Any user can run it; the menu bar's **Done — Rotate Now** uses it. |
| `-showConfig` | The settings in effect, which preference domain each came from, and whether it's managed, set locally or a default. `FirstPass` is never printed. |
| `-uninstall` | Removes the app, LaunchDaemons, LaunchAgent, symlink and receipts. The stored password is kept, so a reinstall carries on. |
| `-uninstall -purge` | Also deletes the stored passwords, the state and the logs. Make sure your MDM has the password first. |
| `-getPassword` | **Deprecated, removed in 5.0.** Copies the password to a temporary keychain item for 3.x scripts. Use `-escrow`. |
| `-version` | Prints the version, `4.0.0.<build>`. |
| `-help` | Lists the commands. |

The uninstall script is also in the app, for MDMs that run scripts: `/Applications/macOSLAPS.app/Contents/Resources/uninstall.sh [--purge]`.

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
| `revealCodeSet`, `revealFailures`, `revealLocked`, `revealCodeCollected`, `revealedAt`, `rotatesAt`, `rotateReason` | [Device mode](retrieval/device-mode.md) and `-expireIn` |

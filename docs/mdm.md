# MDM setup

Every MDM can run a script as root and store what it prints. macOSLAPS gives you two commands for that:

| Command | Prints | Use it for |
|---|---|---|
| `macOSLAPS -escrow` | JSON with the password, a CMS block encrypted to `EscrowCertificates`, or the reveal code in device mode | Getting the password (or code) from the MDM |
| `macOSLAPS -status` | One line of JSON describing the account, secureToken, FileVault, the stored password, admins and more | Smart or dynamic groups that catch broken Macs before you need them |

Log messages go to stderr for both, so only the result is captured.

## Ready-made scripts

The [`integrations/`](https://github.com/joshua-d-miller/macOSLAPS/tree/4.0.0.950/integrations) folder has an escrow script and a status script for each:

| MDM | Folder | What to create |
|---|---|---|
| Jamf Pro | [`jamf/`](https://github.com/joshua-d-miller/macOSLAPS/tree/4.0.0.950/integrations/jamf) | Extension attributes (String, Script) |
| Microsoft Intune | [`intune/`](https://github.com/joshua-d-miller/macOSLAPS/tree/4.0.0.950/integrations/intune) | Custom attributes for macOS |
| Workspace ONE | [`workspace-one/`](https://github.com/joshua-d-miller/macOSLAPS/tree/4.0.0.950/integrations/workspace-one) | Sensors |
| Iru (Kandji), Mosyle, Addigy and others | [`generic/`](https://github.com/joshua-d-miller/macOSLAPS/tree/4.0.0.950/integrations/generic) | Whatever your MDM calls a custom inventory script |

For Jamf Pro there are also the [`jamf Extension Attributes/`](https://github.com/joshua-d-miller/macOSLAPS/tree/4.0.0.950/jamf%20Extension%20Attributes) (password only, expiration only, or both), and Henri Kovanen's [`MDM Scripts/`](https://github.com/joshua-d-miller/macOSLAPS/tree/4.0.0.950/MDM%20Scripts) for installing macOSLAPS and reporting from any MDM.

!!! tip "Replace scripts from 3.x"
    Earlier scripts read the old keychain item or the old path, and mishandled passwords containing a backslash. Use this release's.

## Settings profile

Deliver settings in a configuration profile for the preference domain `com.joshua-d-miller.macoslaps`:

- **Jamf Pro:** Configuration Profiles → Application & Custom Settings → Upload, preference domain `com.joshua-d-miller.macoslaps`, and paste the [custom schema](https://github.com/joshua-d-miller/macOSLAPS/blob/4.0.0.950/Profile%20Manifests/com.joshua-d-miller.macoslaps.json). Every setting then appears as a form with its default and allowed values.
- **iMazing Profile Editor** and other editors that read ProfileManifests: the [manifest](https://github.com/joshua-d-miller/macOSLAPS/blob/4.0.0.950/Profile%20Manifests/com.joshua-d-miller.macoslaps.plist).
- **Any MDM** that uploads a plist: start from the [example](https://github.com/joshua-d-miller/macOSLAPS/blob/4.0.0.950/PLIST%20Example/com.joshua-d-miller.macoslaps.plist).

The [settings reference](settings.md) lists every key.

Two more payloads help:

- **Managed Login Items** (Service Management) with team identifier `9UYK4F9BSM`: no "Background Items Added" notification, and users can't turn macOSLAPS off.
- **Notifications** for `com.joshua-d-miller.macoslaps`, if you use [device mode](retrieval/device-mode.md).

## Groups worth building from `-status`

| `-status` field | Value | Means |
|---|---|---|
| `passwordVerifies` | `false` | The stored password doesn't work for the account |
| `migration` | `required` | The 3.x password couldn't be migrated; see [Upgrading](upgrading.md#if-the-migration-cant-finish) |
| `externalChange` | set | Something else changed the password; rotation is stopped |
| `lastResult` | `failed` | The last run failed; `lastMessage` says why |
| `unapprovedAdmins` | not empty | Admins that aren't approved (with `AdminGroupPolicy report`, or before they're removed) |
| `passwordIsFirstPass` | `true` | The account still has the shared `FirstPass` password |
| `revealLocked` | `true` | Device mode: too many wrong codes |
| `escrowCertificatesExpire` | soon | An escrow certificate needs replacing |

## Refreshing inventory after a rotation

Set `InventoryHook jamf` to run `jamf recon` after each rotation, or `InventoryHook custom` with your agent's command in `InventoryHookCommand`. See [staged rotation](retrieval/escrow.md#staged-rotation) for how this keeps your MDM in step.

## One account, one owner

Running macOSLAPS and your MDM's built-in LAPS on **the same account** is a conflict, not redundancy: each changes the password the other stored. On **different** accounts they're fine together.

- **Jamf Pro:** the LAPS feature for the management account manages that account; the MDM LAPS feature manages the PreStage admin.
- **Intune:** its macOS LAPS manages only the ADE-created admin on new enrollments.
- **Platform SSO:** don't point macOSLAPS at an account that signs in with Platform SSO.

Choose macOSLAPS for an account when you want Active Directory, encrypted escrow, device-mode reveals, one tool across several MDMs, or an admin that can unlock FileVault. If two tools have fought over an account, macOSLAPS stops with `externalChange`; see [secureToken and FileVault](secure-token.md#when-something-else-changes-the-password).

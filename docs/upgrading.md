# Upgrading from 3.x

macOSLAPS 4.0 installs over 3.x and over the earlier 4.0.0 (845) prerelease, and moves the stored password to its new keychain item on its first run. Read this page before you deploy it.

## Before you install

1. **Check the admin group.** Admin group protection is new and on by default: the first run removes admins you haven't approved. Set `ApprovedAdmins`, or `AdminGroupPolicy report`, in your profile first. See [Admin group protection](admin-group.md).
2. **Move your profile to the new domain** when you can: `com.joshua-d-miller.macoslaps`. The keys are unchanged. Profiles for `edu.psu.macoslaps` keep working through 4.x with a warning in the log, and you can split settings across both (the new domain wins key by key).
3. **Update anything that looks for the old names** (see [What to watch out for](#what-to-watch-out-for)).
4. **Replace your MDM scripts and extension attributes** with this release's. They use the new paths, and the earlier ones mishandled passwords containing a backslash.
5. **Make sure your MDM has the current password** (`-escrow` or your inventory), in case you need to roll back.

## What changes on the Mac

4.0 replaces the `edu.psu` identifiers it inherited from Penn State with its own.

| | 3.x and 4.0.0 (845) | 4.0 |
|---|---|---|
| Program | `/usr/local/laps/macOSLAPS` | `/Applications/macOSLAPS.app` (the old path is a symlink to it through 4.x) |
| Code-signing identifier | `edu.psu.macOSLAPS` | `com.joshua-d-miller.macoslaps`; a small migration helper inside the app keeps `edu.psu.macOSLAPS` |
| Password in the System keychain | `macOSLAPS` (and `macOSLAPS-pending` in earlier 4.0 test builds) | `com.joshua-d-miller.macoslaps` (and `.pending`; `.reveal` holds the device-mode code) |
| Settings domain | `edu.psu.macoslaps` | `com.joshua-d-miller.macoslaps` (the old domain is still read through 4.x) |
| LaunchDaemons | `edu.psu.macoslaps-check` | `com.joshua-d-miller.macoslaps-check`, `com.joshua-d-miller.macoslaps-service` |
| LaunchAgent | none | `com.joshua-d-miller.macoslaps.agent` (menu bar countdown) |
| Package receipts | `edu.psu.macOSLAPS`, `edu.psu.macOSLAPS-check` | `com.joshua-d-miller.macoslaps`, `com.joshua-d-miller.macoslaps-check` (the old ones are forgotten) |
| Log | `/Library/Logs/macOSLAPS.log` | `/Library/Application Support/macOSLAPS/Logs/macOSLAPS.log`, with a symlink at the old path; also the unified log |
| 3.x plaintext files | `/var/root/Library/Application Support/macOSLAPS-password` and `-expiration` | deleted without being read |

## How the migration works

The old keychain item only trusts programs signed `edu.psu.macOSLAPS`, so on its first run 4.0 reads it through the helper inside the app. Then it:

1. checks that the password actually works for the account;
2. saves it in the new item, keeping its original creation date, so the next rotation is still due on schedule;
3. overwrites the old item, then deletes it;
4. deletes the old `-getPassword` export and the 3.x plaintext files, without reading them.

`-status` reports `"migration": "migrated"` with `migratedAt` and `migratedFrom`.

### If the migration can't finish

If no stored password works, nothing is changed. `-status` reports `"migration": "required"`, and macOSLAPS stops rotating until you give it the account's current password:

```bash
printf '%s\n' "$current_password" | sudo macOSLAPS -firstPass - -initialize
```

`-initialize` stores the password without rotating. Use `-resetPassword` instead to rotate right away. Only the signed release can migrate: a copy you build or sign yourself can't read the old item and reports "migration required".

## What to watch out for

- **Scripts or extension attributes that read the keychain directly** (`security find-generic-password -s macOSLAPS …`) find nothing after the migration. Use `macOSLAPS -escrow` or `-status`, or this release's scripts.
- **Smart groups, patch definitions, Munki `installs` items or compliance checks** keyed on the `edu.psu.macOSLAPS` receipt or on `/usr/local/laps/macOSLAPS` need the new receipt or the app (`CFBundleShortVersionString` 4.0.0, `CFBundleVersion` = the build).
- **Managed Login Items or PPPC profiles** naming `edu.psu.macoslaps-check` or `edu.psu.macOSLAPS`: switch them to team identifier `9UYK4F9BSM`, which covers both LaunchDaemons and the LaunchAgent. System Settings now shows "macOSLAPS" for them rather than a developer name.
- **Scripts that call the full path** `/usr/local/laps/macOSLAPS` keep working through 4.x but log a deprecation notice. The path is removed in 5.0. Use `macOSLAPS` (on the `PATH`) or the app path.
- **The app-only package over 845.** The `-Binary-` package alone leaves the old `edu.psu.macoslaps-check` LaunchDaemon running through the legacy symlink. It works, with the deprecation notice. Install the full or `-LD-` package to switch to the new LaunchDaemons.
- **The combined Jamf extension attribute was renamed** `Password and Expiration Combined.zsh`. The colon in the old name broke checkouts on Windows.

## Rolling back

Older versions can't read the new keychain item, so there's no in-place downgrade. To roll back:

1. Collect the current password (`-escrow`, or your MDM's inventory).
2. Run `sudo macOSLAPS -uninstall`. This keeps the stored password and stops two LaunchDaemons from running side by side.
3. Install 3.0.4 or 4.0.0 (845).
4. Set `FirstPass` to that password in your profile and run `-resetPassword`.

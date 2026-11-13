# Troubleshooting

## Start here

```bash
sudo macOSLAPS -status -v     # a checklist, with what to do about each problem
sudo macOSLAPS -showConfig    # the settings in effect and where they came from
```

Include both when you ask for help in #laps or open an issue. Neither prints a password.

## Logs

- **The log file:** `/Library/Logs/macOSLAPS.log` (a symlink to `/Library/Application Support/macOSLAPS/Logs/macOSLAPS.log`). It rotates at 5 MB and keeps four old copies. The 3.x log is kept as `macOSLAPS-3x.log`.
- **The unified log:**

    ```bash
    log show --predicate 'subsystem == "com.joshua-d-miller.macoslaps"' --info --last 1d
    ```

## Common problems

**"Migration required"**
:   4.0 couldn't use the password stored by 3.x or 845: it was missing or no longer worked. Give macOSLAPS the account's current password with `-firstPass - -initialize`. See [Upgrading](upgrading.md#if-the-migration-cant-finish).

**"The password was changed outside macOSLAPS; rotation is stopped"** (`externalChange`)
:   Something else changed the password: your MDM's LAPS, another tool, or a person. Decide which tool owns the account, then run `-firstPass - -resetPassword` with the current password. See [secureToken and FileVault](secure-token.md#when-something-else-changes-the-password).

**The stored password doesn't work** (`passwordVerifies false`)
:   Usually the same as above. If staged rotation is on, also try the `pending` password from `-escrow`.

**The first rotation fails on a secureToken account**
:   macOSLAPS needs the account's current password once. Set `FirstPass` or use `-firstPass -`. See [secureToken and FileVault](secure-token.md).

**Settings seem ignored**
:   Check `-showConfig`. Make sure the profile's domain is `com.joshua-d-miller.macoslaps` (or the legacy `edu.psu.macoslaps`), and that `Method` is `Local` for MDM setups: the built-in default is `AD`.

**An admin was removed that shouldn't have been**
:   Add it to `ApprovedAdmins` and add it back to the admin group. See [Admin group protection](admin-group.md). `demotedAdmins` in `-status` lists who was removed and when.

**`-escrow` prints an error and no password**
:   `EscrowCertificates` is set but none of the certificates is usable. `-status -v` says which and why. This is deliberate: it never falls back to plain text.

**Device mode: "Too many wrong codes"**
:   Five wrong codes lock reveals. `sudo macOSLAPS -resetPassword` rotates and issues a new code.

**Device mode: the window says the service didn't answer**
:   Check that `com.joshua-d-miller.macoslaps-service` is loaded (`sudo launchctl print system/com.joshua-d-miller.macoslaps-service`), and that a Managed Login Items rule isn't blocking it.

## Removing macOSLAPS

```bash
sudo macOSLAPS -uninstall          # keeps the stored password
sudo macOSLAPS -uninstall -purge   # also deletes passwords, state and logs
```

Profiles are your MDM's and aren't touched.

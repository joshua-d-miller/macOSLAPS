# secureToken and FileVault

## Why the old password matters

On APFS, accounts that can unlock FileVault hold a **secureToken**. Most admins created by Setup Assistant or an MDM get one. macOS can only change a secureToken account's password, and keep its FileVault access, when **the old password is known**. Resetting it without the old password would cost the account its token.

So for an account with a secureToken, macOSLAPS must know the current password before its first rotation. After that it always has the previous password, because it stored it.

## Giving macOSLAPS the first password

Either:

- set the **`FirstPass`** key in your profile to the account's current password, and remove it once Macs have rotated (`-status -v` warns while the password is still the `FirstPass` one); or
- run the first rotation from your MDM, which keeps the password out of the profile:

    ```bash
    printf '%s\n' "$current_password" | macOSLAPS -firstPass - -resetPassword
    ```

    `-initialize` instead of `-resetPassword` stores the password without rotating; the first rotation then happens after `DaysTillExpiration`.

`-firstPass <password>` on the command line still works, but logs a warning: other processes can see command lines.

## How rotation stays safe

- **It fails closed.** The account counts as having no secureToken only when `sysadminctl` says so plainly. An error, a timeout or odd output is treated like a token, so the old password is required and a token is never lost by mistake.
- **Change, verify, store.** macOSLAPS changes the password, checks the new one works, then stores it. If any step fails, it puts the old password back.
- **Interruptions are held off.** Stop signals wait until the change is stored, and only one rotation runs at a time.
- **The login keychain.** After a rotation, the admin's login keychain would still be locked with the old password. `RemoveKeychain` (default `true`) deletes it, so logging in as the admin doesn't bring up keychain prompts.

## When something else changes the password

If the stored password stops working because something else changed it (another LAPS tool, the MDM, a technician), macOSLAPS **stops rotating** rather than forcing a reset, even when the account has no secureToken. `-status` reports `externalChange` and why.

To manage the account again, decide which tool owns it, then give macOSLAPS the current password:

```bash
printf '%s\n' "$current_password" | sudo macOSLAPS -firstPass - -resetPassword   # or -initialize
```

## Bootstrap token

`-status` also reports whether the Mac has escrowed a bootstrap token to your MDM (`bootstrapTokenEscrowed`). That's what lets new accounts get a secureToken at login, so it's worth checking alongside FileVault (`fileVault`) and the recovery key escrow profile (`recoveryKeyEscrowProfile`).

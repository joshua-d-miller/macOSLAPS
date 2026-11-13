# Getting the password

macOSLAPS keeps the password on the Mac, in the System keychain, and makes it available to IT in one of four ways. Pick one per Mac with `RetrievalMode` and `Method`. Different Macs can use different ways.

| | Settings | Where the password is | How IT gets it |
|---|---|---|---|
| **[Escrow](escrow.md)** (default) | `Method Local`, `RetrievalMode escrow` | On the Mac and in your MDM's inventory, in plain text | The inventory attribute filled by `macOSLAPS -escrow` |
| **[Encrypted escrow](encrypted-escrow.md)** | as above, plus `EscrowCertificates` | On the Mac and in your MDM's inventory, **encrypted**. Neither the MDM nor anyone who can read inventory sees it | Decrypt the inventory value with your private key |
| **[Device mode](device-mode.md)** | `RetrievalMode device` | **Only on the Mac.** Your MDM holds a reveal code instead | A technician enters the code on the Mac |
| **[Active Directory](active-directory.md)** | `Method AD` | On the computer object | ADUC, `Get-LapsADPassword`, or your LAPS tool |

## Which one?

- **Escrow** is the simplest and works with every MDM. Anyone who can read your MDM's inventory can read the password, so limit who can see that attribute.
- **Encrypted escrow** is escrow without trusting the MDM: the password is encrypted to certificates whose private keys only your admins hold. Use it when the MDM is shared, hosted, or has many admins.
- **Device mode** keeps the password off every server. A technician sees it only at the Mac, every reveal is logged with who and why, and the password changes a few hours later. It needs someone at the Mac, after login: it can't help at the FileVault unlock screen, so escrow the FileVault recovery key too.
- **Active Directory** suits Macs bound to AD that you already manage with Windows LAPS tools.

Encrypted escrow and device mode can be combined: `EscrowCertificates` then encrypts the reveal code too.

## Changing the password after use

Whichever way IT got the password, change it once the job is done:

- `sudo macOSLAPS -expireIn 4h` changes it in four hours (or `30m`, `2h30m`, `0` for the next run). The menu bar counts down to it, and the deadline is met on time even between scheduled runs.
- `sudo macOSLAPS -resetPassword` changes it now.
- In device mode this happens on its own after `RevealGracePeriod`.

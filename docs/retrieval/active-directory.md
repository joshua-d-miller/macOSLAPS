# Active Directory

With `Method AD`, macOSLAPS writes the password and its expiration to the Mac's computer object in Active Directory, like LAPS for Windows. It's the original way macOSLAPS worked, and the built-in default for `Method`.

## Requirements

- The Mac is **bound to Active Directory** and can reach a **writable domain controller** (on site or over VPN) when it rotates. Set `PreferredDC` to pick one.
- **The computer object may write its own LAPS attributes.** Grant that with the cmdlet for your schema, on the OU holding your Macs:
    - legacy LAPS: `Set-AdmPwdComputerSelfPermission -OrgUnit "<OU>"`
    - Windows LAPS: `Set-LapsADComputerSelfPermission -Identity "<OU>"`

macOSLAPS checks that it can write to AD before changing the password.

## Schemas

`ADSchema` picks the attributes:

| `ADSchema` | Password attribute | Expiration attribute | Read it with |
|---|---|---|---|
| `legacy` (default) | `ms-Mcs-AdmPwd` | `ms-Mcs-AdmPwdExpirationTime` | The legacy LAPS UI, `Get-AdmPwdPassword` |
| `windowsLAPS` | `msLAPS-Password` (JSON with the account, time and password) | `msLAPS-PasswordExpirationTime` | The ADUC LAPS tab, `Get-LapsADPassword` |
| `both` | both of the above | both | either |

!!! warning "Experimental"
    `windowsLAPS` and `both` are new in 4.0 and haven't been tested against a real domain yet. Please [report how they work](../testing.md) for you. Windows LAPS encrypted passwords (`msLAPS-EncryptedPassword`) aren't supported.

## Device mode with AD

In [device mode](device-mode.md), the password is never written to AD; only the expiration is. With `ADRevealCode true` the reveal code goes into the password attribute instead, so technicians look it up where they're used to.

## Entra ID

Microsoft Entra ID has no supported way for non-Windows devices to store LAPS passwords. With Intune, use custom attributes with `-escrow` (ideally [encrypted](encrypted-escrow.md)) or [device mode](device-mode.md).

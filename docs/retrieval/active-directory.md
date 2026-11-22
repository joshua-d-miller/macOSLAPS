# Active Directory

With `Method AD`, macOSLAPS writes the password and its expiration to the Mac's computer object in Active Directory, like LAPS for Windows. It's the original way macOSLAPS worked, and what the default `Method auto` picks on a Mac bound to Active Directory.

## Requirements

- The Mac is **bound to Active Directory** and can reach a **writable domain controller** (on site or over VPN) when it rotates. See [Read-only domain controllers](#read-only-domain-controllers-and-preferreddc).
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

!!! info "Tested against Samba"
    Every build binds a Mac to a Samba domain with both schemas and checks `legacy`, `windowsLAPS` and `both` end to end, plus `ADRevealCode`. They haven't been tested against Windows Server domain controllers yet: please [report how they work](../testing.md) for you. Windows LAPS encrypted passwords (`msLAPS-EncryptedPassword`) aren't supported.

## Read-only domain controllers and PreferredDC

macOSLAPS normally reads and writes through the Mac's Active Directory binding, on whichever domain controller the binding uses. Two settings change that:

- **`PreferredDC`** (a domain controller's full DNS name, e.g. `dc1.example.com`): macOSLAPS reads and writes only there, over LDAP.
- **A read-only bound DC:** when the binding's domain controller doesn't take the write (an RODC, for example), macOSLAPS looks up the domain controllers in DNS (`_ldap._tcp.dc._msdcs.<domain>`) and uses the first one that takes it. (macOS often follows the RODC's referral to a writable DC by itself; then nothing more is needed.)
- **Open Directory can't reach AD:** while the Mac is bound, if Open Directory can't open the Active Directory node (for example, the domain controller it wants is unreachable but others are), macOSLAPS uses the first domain controller in DNS that answers over LDAP. If that one is read-only, it moves on to the next one that takes the write.

macOSLAPS checks that a domain controller takes writes before it changes the password, by moving the expiration time forward 100 ns and back. A write that changes nothing isn't proof: some read-only domain controllers accept it.

Over LDAP, macOSLAPS signs in **as the computer account**, the same identity the binding uses, so the self-write permission above is all it needs. The computer's password comes from the System keychain item the binding created (`/Active Directory/<DOMAIN>`). The Kerberos ticket goes into a private cache that is removed when the run ends, and the session is signed and encrypted (GSSAPI). Nothing secret is put on a command line.

At sites with read-only domain controllers, set `PreferredDC`: then the expiration time is also read from a domain controller that has the current value.

## Device mode with AD

In [device mode](device-mode.md), the password is never written to AD; only the expiration is. With `ADRevealCode true` the reveal code goes into the password attribute instead, so technicians look it up where they're used to.

## Entra ID

Microsoft Entra ID has no supported way for non-Windows devices to store LAPS passwords. With Intune, use custom attributes with `-escrow` (ideally [encrypted](encrypted-escrow.md)) or [device mode](device-mode.md).

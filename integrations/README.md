# MDM integrations

Every MDM can run a script as root and store what it prints. macOSLAPS 4.0 provides two commands for that:

| Command | Output | Use it for |
|---|---|---|
| `macOSLAPS -escrow` | JSON with the password, or a CMS block encrypted to `EscrowCertificates` | Retrieving the password from the MDM |
| `macOSLAPS -status` | One line of JSON (account, secureToken, FileVault, whether the stored password works, escrow mode, ...) | Smart / dynamic groups that catch broken Macs before you need them |

Log messages go to stderr for these commands, so only the result is captured.

| Folder | MDM |
|---|---|
| `jamf/` | Jamf Pro extension attributes (String) |
| `intune/` | Intune custom attributes for macOS |
| `workspace-one/` | Workspace ONE sensors |
| `generic/` | Anything else (Iru/Kandji, Mosyle, Addigy, ...) |

## Staged rotation (4.0)
With `StagedRotation` on (or `auto`, the default, once your MDM runs `-escrow`), a new password is first stored as **pending** and `-escrow` reports it next to the current one (`"pending"`, `"pendingSet"`). macOSLAPS changes the account to it only after `-escrow` has reported it `EscrowConfirmations` times (default 2), so your MDM always has the password the Mac is using. Keep both values: if the current password doesn't work, try the pending one.

To refresh inventory right after a rotation, set `InventoryHook` to `jamf`, or to `custom` with `InventoryHookCommand` for your MDM's agent command.

## Decrypting CMS escrow
Copy the whole block, including the `-----BEGIN CMS-----` / `-----END CMS-----` lines, into a file `escrow.txt`, then:

- **Windows:** `Unprotect-CmsMessage -Path .\escrow.txt` (the certificate and private key must be in your certificate store)
- **macOS:** `sed '1d;$d' escrow.txt | base64 -D > escrow.der && security cms -D -i escrow.der` (identity in your keychain)
- **Linux/macOS with OpenSSL:** `openssl cms -decrypt -inform PEM -in escrow.txt -recip cert.pem -inkey key.pem`

Use RSA certificates. For Windows, the certificate needs the Document Encryption EKU (`1.3.6.1.4.1.311.80.1`); `New-SelfSignedCertificate -Type DocumentEncryptionCert -Subject "CN=macOSLAPS Escrow"` creates one. Put the public certificate (PEM or base64) in the `EscrowCertificates` array; keep the private key with your admins.

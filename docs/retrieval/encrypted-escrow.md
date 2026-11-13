# Encrypted escrow (CMS)

Encrypted escrow keeps the password out of your MDM's database in readable form, while the MDM still holds a copy for when the Mac can't be reached. `macOSLAPS -escrow` encrypts its output to one or more certificates with CMS (PKCS #7, AES-256). Only someone with a matching private key can read it.

## Set it up

1. **Create an RSA certificate for each admin or team.** On Windows:

    ```powershell
    New-SelfSignedCertificate -Type DocumentEncryptionCert -Subject "CN=macOSLAPS Escrow"
    ```

    For Windows decryption the certificate needs the Document Encryption EKU (`1.3.6.1.4.1.311.80.1`), which this command adds. Keep the private keys with your admins, ideally on a smart card or YubiKey, plus an **offline recovery certificate** in a safe.

2. **Put the public certificates in `EscrowCertificates`**, one per array item, as PEM text or base64 DER. Every listed certificate can decrypt.

    ```xml
    <key>EscrowCertificates</key>
    <array>
        <string>-----BEGIN CERTIFICATE-----
    MIIC…
    -----END CERTIFICATE-----</string>
    </array>
    ```

3. **Collect `-escrow` as before.** It now prints a block like this, about 1 KB per certificate, instead of JSON:

    ```text
    -----BEGIN CMS-----
    MIAGCSqGSIb3DQEHA6CAMIACAQIxggE…
    -----END CMS-----
    ```

    Store it in an inventory attribute that keeps line breaks. Inside is the same JSON as plain [escrow](escrow.md).

It fails closed: if `EscrowCertificates` is set but none of the certificates is usable, `-escrow` prints an error and **no password**. `-status -v` warns when a certificate is unusable or about to expire.

## Read it

Copy the whole block, including the `BEGIN` and `END` lines, into `escrow.txt`:

=== "Windows"

    ```powershell
    Unprotect-CmsMessage -Path .\escrow.txt
    ```

    The certificate and its private key must be in your certificate store. Works in PowerShell 7 and Windows PowerShell 5.1; CI checks both on every build.

=== "macOS"

    ```bash
    sed '1d;$d' escrow.txt | base64 -D > escrow.der && security cms -D -i escrow.der
    ```

    The identity must be in your keychain or on a smart card.

=== "OpenSSL"

    ```bash
    openssl cms -decrypt -inform PEM -in escrow.txt -recip cert.pem -inkey key.pem
    ```

## If a private key is compromised

1. Push the profile without the compromised certificate (and with its replacement).
2. Rotate: run `macOSLAPS -resetPassword` on the Macs, with your inventory refresh.
3. Use a report or smart group on the rotation date (`lastRotation` in `-status`) to confirm every Mac rotated.

Old inventory history encrypted to that certificate stays readable to whoever has the key, but after the rotation it only holds dead passwords.

## With device mode

In [device mode](device-mode.md), `EscrowCertificates` encrypts the reveal code instead, so even the code is unreadable in your MDM without a private key.

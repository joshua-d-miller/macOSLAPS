# Security policy

macOSLAPS manages local administrator passwords, so security reports matter a lot.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub:
**Security → Report a vulnerability** on this repository
(<https://github.com/joshua-d-miller/macOSLAPS/security/advisories/new>).

Include what you found, the macOSLAPS version (`/usr/local/laps/macOSLAPS -version`),
the macOS version, and steps to reproduce. Never include real passwords, escrow blobs
or private keys.

You'll get an acknowledgement within a few days. Fixes are released as a new build
and credited in the release notes unless you'd rather not be named.

## Supported versions

| Version | Supported |
|---|---|
| 4.0.x (latest build) | ✅ |
| 3.x and earlier | ❌ — please upgrade |

## What counts

Anything that could expose a managed password or let someone obtain or change it
without authorization: the keychain item, `-escrow` / `-getPassword` output, the
state file in `/var/db/macoslaps`, logs, the installer packages, or the release
pipeline. Weaknesses in a deployment's own MDM or directory permissions are out of
scope, but advice on safe defaults is welcome.

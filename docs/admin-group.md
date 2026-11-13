# Admin group protection

Anyone who knows the managed admin's password can make their own account an admin in Users & Groups. macOSLAPS can't stop that as it happens, but it catches it on its next run (every 90 minutes): only the managed admin, `root` and the accounts you approve may stay in the `admin` group.

!!! danger "On by default"
    On its first run, macOSLAPS 4.0 removes every account from the local `admin` group except:

    - the managed admin (`LocalAdminAccount`);
    - `root`;
    - the accounts and groups in `ApprovedAdmins`;
    - the admin your MDM created during Automated Device Enrollment ([below](#mdm-created-admins)).

    **If your users are admins on purpose, or another tool uses an admin account,** set `ApprovedAdmins` or `AdminGroupPolicy report` in your profile **before** installing.

## Settings

`ApprovedAdmins`
:   An array of short names, or `group:<name>` to approve the members of a group (`group:helpdesk`).

`AdminGroupPolicy`
:   - `auto` (default): remove unapproved admins, unless an elevation tool is installed. Then it only reports, because users become admin on purpose. It recognizes SAP Privileges, Jamf Connect, Admin By Request and Make Me Admin.
    - `report`: only list unapproved admins, in `-status` (`unapprovedAdmins`) and the log.
    - `enforce`: remove them even with an elevation tool installed.

## Safety rails

Whatever the setting:

- macOSLAPS never touches `root` or the managed admin.
- It removes nobody unless the managed admin exists, is an admin, and macOSLAPS has just verified its stored password. A Mac is never left without a working admin.
- It removes only direct members of `admin`. Nested groups are reported, not changed.
- On an MDM-enrolled Mac, if the list of MDM-created admins can't be read, it removes nobody on that run and says why in `-status`.
- Every removal is logged and listed in `-status` (`demotedAdmins`).

**Check before deploying:** `sudo macOSLAPS -status -v` lists the admins that would be removed under "Admins not in ApprovedAdmins".

## MDM-created admins

When your MDM creates an admin during Automated Device Enrollment (the Jamf Pro PreStage admin, the Intune ADE admin, the Iru Auto Admin, and so on), macOS records it. macOSLAPS reads that record (`AutoSetupAdminAccounts` in `mdmclient QueryDeviceInformation`), matches both the account's ID and its short name, and never removes those accounts. `-status` lists them under `mdmAdmins`.

Two cases need `ApprovedAdmins`:

- **The Jamf Pro management account from user-initiated enrollment.** macOS has no record of it, so list it if you want it to stay admin.
- **Support or service accounts** created by scripts or packages.

### When the managed admin is the MDM's own account

If `LocalAdminAccount` is the account your MDM created, the MDM can change its password too (its own LAPS feature). macOSLAPS warns once a day, and `-status` reports `localAdminIsMDMAccount`. If your MDM's LAPS is on for that account, let one of them own it. `AllowMDMManagedAccount false` makes macOSLAPS refuse to manage such an account.

!!! example "Help wanted"
    If `-status` doesn't list your MDM's enrollment admin under `mdmAdmins`, please send the `AutoSetupAdminAccounts` block from `sudo /usr/libexec/mdmclient QueryDeviceInformation` in #laps or an issue. See [Testing 4.0](testing.md).

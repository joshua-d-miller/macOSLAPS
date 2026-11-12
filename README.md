![](https://img.shields.io/github/v/release/joshua-d-miller/macOSLAPS)&nbsp;![](https://img.shields.io/github/downloads/joshua-d-miller/macOSLAPS/latest/total)&nbsp;![](https://img.shields.io/badge/macOS-13%2B-success)&nbsp;![](https://img.shields.io/github/license/joshua-d-miller/macOSLAPS)
### macOSLAPS (Local Administrator Password Solution)
macOSLAPS rotates the password of a local administrator account on your Macs to a random value, on a schedule, and keeps it where IT can get it:
- **Escrow mode:** your MDM collects the password with `macOSLAPS -escrow` (plain JSON, or CMS-encrypted to your admins' certificates). Active Directory (legacy LAPS or Windows LAPS attributes) works too.
- **Device mode:** your MDM collects a reveal code instead; a technician enters it on the Mac (in macOSLAPS.app, no admin rights needed) to see the password, which rotates again a few hours later.

It also keeps the admin group to the accounts you approve, and works with any MDM: Jamf Pro, Intune, Workspace ONE, Iru (Kandji), Mosyle and others. Since 4.0 it installs as `/Applications/macOSLAPS.app` and needs macOS 13 or later.

The [release notes](.github/release-notes/4.0.0.md) describe 4.0 in full, including what to check before upgrading. Settings for your MDM: [`Profile Manifests/`](Profile%20Manifests) (Jamf custom schema and iMazing manifest) and [`PLIST Example/`](PLIST%20Example).

### How To
The Wiki, **[here](https://www.github.com/joshua-d-miller/macOSLAPS/wiki)**, describes 3.x. For 4.0, the release notes and `macOSLAPS -help` are the reference.

### Preference domain
Starting with 4.0.0, configuration profiles should use the preference domain (PayloadType) `com.joshua-d-miller.macoslaps`. The keys are unchanged. Profiles using the original `edu.psu.macoslaps` domain continue to work throughout 4.x and log a deprecation warning. Run `sudo macOSLAPS -showConfig` (the installer puts `/Applications/macOSLAPS.app/Contents/MacOS` on the PATH) to see which settings are in effect and where they came from.

### Feedback and Questions
If you have questions you can contact me or the vibrant and friendly community in the [#laps](https://macadmins.slack.com/archives/C68F4NLFL) channel on **[MacAdmins Slack](https://macadmins.org)**.

### History
macOSLAPS was originally created while I was at The Pennsylvania State University, which is where the `edu.psu` identifiers come from. Thank you to Penn State for the start. The project is now maintained independently.

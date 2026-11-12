![](https://img.shields.io/github/v/release/joshua-d-miller/macOSLAPS)&nbsp;![](https://img.shields.io/github/downloads/joshua-d-miller/macOSLAPS/latest/total)&nbsp;![](https://img.shields.io/badge/macOS-13%2B-success)&nbsp;![](https://img.shields.io/github/license/joshua-d-miller/macOSLAPS)
### macOSLAPS (Local Administrator Password Solution)
Swift binary that utilizes Open Directory in order to perform passwords changes for a specified local administrator. The password is randomly generated and can be configured with your own settings. Make the password as long or as short as your want.

### How To
The README.md has had the information moved to the Wiki which you can access **[here](https://www.github.com/joshua-d-miller/macOSLAPS/wiki)**

### Preference domain
Starting with 4.0.0, configuration profiles should use the preference domain (PayloadType) `com.joshua-d-miller.macoslaps`. The keys are unchanged. Profiles using the original `edu.psu.macoslaps` domain continue to work throughout 4.x and log a deprecation warning. Run `sudo macOSLAPS -showConfig` (the installer puts `/Applications/macOSLAPS.app/Contents/MacOS` on the PATH) to see which settings are in effect and where they came from.

### Feedback and Questions
If you have questions you can contact me or the vibrant and friendly community in the [#laps](https://macadmins.slack.com/archives/C68F4NLFL) channel on **[MacAdmins Slack](https://macadmins.org)**.

### History
macOSLAPS was originally created while I was at The Pennsylvania State University, which is where the `edu.psu` identifiers come from. Thank you to Penn State for the start. The project is now maintained independently.

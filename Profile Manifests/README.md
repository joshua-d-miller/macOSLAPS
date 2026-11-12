# Profile Manifests

Every macOSLAPS 4.x setting (preference domain `com.joshua-d-miller.macoslaps`), with its type, built-in default and allowed values.

| File | Use it with |
| --- | --- |
| `com.joshua-d-miller.macoslaps.json` | **Jamf Pro:** Configuration Profiles → Application & Custom Settings → Upload. Preference domain `com.joshua-d-miller.macoslaps`, then paste this file as the custom schema. |
| `com.joshua-d-miller.macoslaps.plist` | **iMazing Profile Editor** and other editors that read [ProfileManifests](https://github.com/ProfileManifests/ProfileManifests). Use it as a custom manifest. |

Leave a key unset to use its default. `sudo macOSLAPS -showConfig` shows what a Mac actually uses and where each value came from.

`FirstPass` holds a password. It is marked sensitive here, and `-showConfig` never prints it. Remove it from the profile once the Mac has rotated.

CI fails if a setting in `macOSLAPS/Preferences/Preferences.swift` is missing from either file or from `PLIST Example/com.joshua-d-miller.macoslaps.plist`.

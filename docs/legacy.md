# macOSLAPS 3.x (legacy)

These pages describe macOSLAPS 4.0. **The documentation for 3.x stays on the [GitHub wiki](https://github.com/joshua-d-miller/macOSLAPS/wiki)** and isn't updated any more:

- [Getting started (3.x)](https://github.com/joshua-d-miller/macOSLAPS/wiki)
- [Configuration keys](https://github.com/joshua-d-miller/macOSLAPS/wiki/Configuration-Keys)
- [Command-line flags](https://github.com/joshua-d-miller/macOSLAPS/wiki/Command-Line-Flags)
- [Example configuration](https://github.com/joshua-d-miller/macOSLAPS/wiki/Example-Configuration)
- [secureToken](https://github.com/joshua-d-miller/macOSLAPS/wiki/secureToken)
- [Managed Login Item](https://github.com/joshua-d-miller/macOSLAPS/wiki/Managed-Login-Item)

Most of it still applies to 4.0: the configuration keys are unchanged, and 4.0 still reads the 3.x preference domain. What changed is covered in [Upgrading from 3.x](upgrading.md).

## Which version for which Mac

| macOS | Use |
|---|---|
| 13 or later | macOSLAPS 4.0 |
| 12 or earlier | [3.0.4](https://github.com/joshua-d-miller/macOSLAPS/releases/tag/3.0.4%28781%29) (see its release notes for the oldest macOS it supports), or 4.0.0 (845) on macOS 12 |
| Very old macOS | [macOSLAPS-Legacy](https://github.com/joshua-d-miller/macOSLAPS-Legacy) |

The 3.0.4 and 4.0.0 (845) packages will be re-signed before Apple retires the signing authority they use, on February 1, 2027. Their contents won't change, but their SHA-256 checksums will.

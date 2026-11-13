# Credits

macOSLAPS started at The Pennsylvania State University. Thank you to Penn State for the start, and to everyone who has helped since.

- **Code over the years:** [@neilmartin83](https://github.com/neilmartin83), [@apizz](https://github.com/apizz), [@MagerValp](https://github.com/MagerValp), [@discentem](https://github.com/discentem), [@dechkovanen](https://github.com/dechkovanen) and [@bartreardon](https://github.com/bartreardon).
- **In this release:** Henri Kovanen for the MDM install and inventory scripts; [@TobiasSplinter](https://github.com/TobiasSplinter) for the Windows LAPS schema work ([#102](https://github.com/joshua-d-miller/macOSLAPS/issues/102), [#103](https://github.com/joshua-d-miller/macOSLAPS/issues/103)); [@Melvin-P-NL](https://github.com/Melvin-P-NL) for the password-length fix ([#121](https://github.com/joshua-d-miller/macOSLAPS/issues/121)); and a former Penn State colleague for the real `AutoSetupAdminAccounts` output that the MDM-created admin detection is tested against.
- **The reports that shaped 4.0:** [@rougegoat](https://github.com/rougegoat) ([#75](https://github.com/joshua-d-miller/macOSLAPS/issues/75)), [@tlcarpenter](https://github.com/tlcarpenter) ([#86](https://github.com/joshua-d-miller/macOSLAPS/issues/86)), [@staze](https://github.com/staze) ([#88](https://github.com/joshua-d-miller/macOSLAPS/issues/88)), [@brianhm](https://github.com/brianhm) ([#92](https://github.com/joshua-d-miller/macOSLAPS/issues/92), [#93](https://github.com/joshua-d-miller/macOSLAPS/issues/93)), [@GabrielKemp](https://github.com/GabrielKemp) ([#96](https://github.com/joshua-d-miller/macOSLAPS/issues/96)), [@mhu4711](https://github.com/mhu4711) ([#104](https://github.com/joshua-d-miller/macOSLAPS/issues/104)), [@mruepp](https://github.com/mruepp) ([#106](https://github.com/joshua-d-miller/macOSLAPS/issues/106)), [@FocusTechnologiesAdmin](https://github.com/FocusTechnologiesAdmin) ([#109](https://github.com/joshua-d-miller/macOSLAPS/issues/109)), [@AndreaDelmonte](https://github.com/AndreaDelmonte) ([#110](https://github.com/joshua-d-miller/macOSLAPS/issues/110)), [@dmmueller](https://github.com/dmmueller) ([#112](https://github.com/joshua-d-miller/macOSLAPS/issues/112)), [@BenjaminHoegh](https://github.com/BenjaminHoegh) ([#117](https://github.com/joshua-d-miller/macOSLAPS/issues/117), [#118](https://github.com/joshua-d-miller/macOSLAPS/issues/118)), [@wakco](https://github.com/wakco) ([#119](https://github.com/joshua-d-miller/macOSLAPS/issues/119)) and [@security-josh](https://github.com/security-josh) ([#120](https://github.com/joshua-d-miller/macOSLAPS/issues/120)). Device mode, `-expireIn`, encrypted escrow and the safer rotation all started as one of these issues.
- **The #laps channel on MacAdmins Slack,** for years of questions, testing and patience. Please keep it coming with this prerelease.

## From the 3.x documentation

These people helped build macOSLAPS in its early years:

- [Rusty Myers](https://github.com/rustymyers): working out the difference between Windows time and epoch time.
- [Matt Hansen](https://github.com/hansen-m): the original random password generator.
- [Per Olofsson](https://github.com/magervalp): the international date format and `PasswordGrouping`.
- Allen Clouser and Jody Harpster: testing, and finding that the `'` key isn't on every Windows keyboard, so it's excluded by default.
- [John Pater](https://github.com/jpat14): the idea of generating ten passwords and picking one at random.
- [Joel Rennich](https://gitlab.com/Mactroll): sample code and answers for changing the password in Active Directory and storing it in the System keychain.
- Peter Szul: making sure macOSLAPS can write to Active Directory before it changes anything.
- **[The MacAdmins community](https://macadmins.org)**, for testing, insight and feedback over the years.

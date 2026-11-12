#!/bin/bash
: <<'HEADER'
===============================================================================
 macOSLAPS | Packaging | build-pkgs.sh
===============================================================================
 Version:   4.0.0
 Author:    Joshua D. Miller, Claude
 Created:   2026-11-10
 Updated:   2026-11-12

 Purpose:
     Builds the three macOSLAPS installer packages:
     macOSLAPS-<version>.pkg         app + /etc/paths.d/laps +
     LaunchDaemon
     macOSLAPS-Binary-<version>.pkg  app + /etc/paths.d/laps
     macOSLAPS-LD-<version>.pkg      LaunchDaemon only
     Most MDMs install a package as-is and can't pass installer choices,
     so the app-only and LaunchDaemon-only packages are how their admins
     pick; the full package keeps the choice IDs of every release for
     installer users. The app goes to /Applications/macOSLAPS.app;
     /usr/local/laps/macOSLAPS is a legacy symlink to it through 4.x.

 Usage:
     build-pkgs.sh <macOSLAPS.app> <version> <outdir> \
         [<Developer ID Installer identity> <keychain>]
     Prints the file name of the full package on the last line.

 Returns:
     Receipts com.joshua-d-miller.macoslaps (app) and
     com.joshua-d-miller.macoslaps-check (LaunchDaemon); the postinstall
     scripts forget the 3.x / 845 receipts and remove the old daemon.
===============================================================================
 CHANGELOG
===============================================================================
 Version   Date         Author    Description
 -------   ----------   -------   --------------------------------------------
 4.0.0     2026-11-12   joshua    Builds from the app bundle; new receipts and
                        claude    label; app not relocatable; paths.d points
                                  into the app; the service daemon and its
                                  request folder.

                                  New header and section style.
===============================================================================
HEADER
# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------- ###
### | Setup | ###
### --------- ###
### Arguments and a work folder.                                            ###
set -euo pipefail

APP=$1; VERSION=$2; OUT=$3; IDENTITY=${4:-}; KEYCHAIN=${5:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-pkgs.sh: version must look like 4.0.0.846, got '$VERSION'" >&2; exit 1; }
MIN_MACOS=${MIN_MACOS:-13.0}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/components"

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ------------------ ###
### | Component: app | ###
### ------------------ ###
### The app, the legacy symlink and /etc/paths.d/laps.                      ###
[ -x "$APP/Contents/MacOS/macOSLAPS" ] || { echo "build-pkgs.sh: $APP is not macOSLAPS.app" >&2; exit 1; }
root="$WORK/root-binary"
mkdir -p "$root/Applications" "$root/usr/local/laps" "$root/private/etc/paths.d"
ditto "$APP" "$root/Applications/macOSLAPS.app"   # keeps the signature intact
ln -s /Applications/macOSLAPS.app/Contents/MacOS/macOSLAPS "$root/usr/local/laps/macOSLAPS"
cp "$HERE/payload/paths.d-laps" "$root/private/etc/paths.d/laps"
chmod 755 "$root/usr/local/laps" "$root/private/etc/paths.d"
chmod 644 "$root/private/etc/paths.d/laps"
codesign --verify --strict --deep "$root/Applications/macOSLAPS.app" >&2
# Not relocatable: the installer must always put the app in /Applications, even when
# another copy with the same bundle ID exists elsewhere (the symlink points there).
pkgbuild --analyze --root "$root" "$WORK/components.plist" >&2
python3 - "$WORK/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
components = plistlib.load(open(path, "rb"))
for c in components:
    c["BundleIsRelocatable"] = False
plistlib.dump(components, open(path, "wb"))
print("components:", [c.get("RootRelativeBundlePath") for c in components], file=sys.stderr)
PY
pkgbuild --root "$root" --component-plist "$WORK/components.plist" --identifier com.joshua-d-miller.macoslaps --version "$VERSION" \
    --scripts "$HERE/app-scripts" --install-location / --ownership recommended "$WORK/components/macoslaps.pkg" >&2

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### --------------------------- ###
### | Component: LaunchDaemon | ###
### --------------------------- ###
### The check and service daemons, the request folder and the install      ###
### scripts.                                                                ###
root="$WORK/root-daemon"
mkdir -p "$root/Library/LaunchDaemons"
for DAEMON in com.joshua-d-miller.macoslaps-check.plist com.joshua-d-miller.macoslaps-service.plist; do
    cp "$REPO/LaunchDaemon/$DAEMON" "$root/Library/LaunchDaemons/"
    chmod 644 "$root/Library/LaunchDaemons/$DAEMON"
    plutil -lint "$root/Library/LaunchDaemons/$DAEMON" >&2
done
# The service's request folder: users may drop a file (rotate now) but not list or
# delete others' files (1733, like /tmp without listing).
mkdir -p "$root/Library/Application Support/macOSLAPS/Requests"
chmod 755 "$root/Library/Application Support/macOSLAPS"
chmod 1733 "$root/Library/Application Support/macOSLAPS/Requests"
chmod 755 "$HERE/app-scripts/postinstall" "$HERE/daemon-scripts/preinstall" "$HERE/daemon-scripts/postinstall"
pkgbuild --root "$root" --identifier com.joshua-d-miller.macoslaps-check --version "$VERSION" \
    --scripts "$HERE/daemon-scripts" --install-location / --ownership recommended \
    "$WORK/components/macoslaps-check.pkg" >&2

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ----------------- ###
### | Distributions | ###
### ----------------- ###
### One choice per component, with the IDs every release used.              ###
distribution() {   # distribution <title> <pkg-ref id>...
    # One choice per component with the same IDs as every release built with
    # Packages (3.x-4.0.0 845): installer_choice_1 = binary, installer_choice_2 =
    # LaunchDaemon. Deployments that skip the LaunchDaemon with
    # "installer -applyChoiceChangesXML" depend on these IDs.
    local title=$1; shift
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<installer-gui-script minSpecVersion="1">'
    echo "    <title>$title</title>"
    echo '    <options require-scripts="false" rootVolumeOnly="true" hostArchitectures="arm64,x86_64"/>'
    echo "    <volume-check><allowed-os-versions><os-version min=\"$MIN_MACOS\"/></allowed-os-versions></volume-check>"
    echo '    <choices-outline>'
    for id in "$@"; do echo "        <line choice=\"$(choice_id "$id")\"/>"; done
    echo '    </choices-outline>'
    for id in "$@"; do
        echo "    <choice id=\"$(choice_id "$id")\" title=\"$(choice_title "$id")\" description=\"\">"
        echo "        <pkg-ref id=\"$id\"/>"
        echo '    </choice>'
    done
    for id in "$@"; do
        echo "    <pkg-ref id=\"$id\" version=\"$VERSION\" onConclusion=\"none\">${id#com.joshua-d-miller.}.pkg</pkg-ref>"
    done
    echo '</installer-gui-script>'
}

choice_id() {      # stable choice IDs, matching earlier releases
    case $1 in
        com.joshua-d-miller.macoslaps)       echo installer_choice_1 ;;
        com.joshua-d-miller.macoslaps-check) echo installer_choice_2 ;;
    esac
}
choice_title() {
    case $1 in
        com.joshua-d-miller.macoslaps)       echo "macOSLAPS" ;;
        com.joshua-d-miller.macoslaps-check) echo "LaunchDaemon" ;;
    esac
}

product() {        # product <output name> <title> <pkg-ref id>...
    local name=$1; shift
    distribution "$@" > "$WORK/$name.dist"
    if [ -z "$IDENTITY" ]; then
        productbuild --distribution "$WORK/$name.dist" --package-path "$WORK/components" "$OUT/$name" >&2
        return
    fi
    # Build unsigned, then sign with productsign (the signing path every earlier
    # release used). Signing inside productbuild can wait on a keychain prompt in CI.
    productbuild --distribution "$WORK/$name.dist" --package-path "$WORK/components" "$WORK/$name" >&2
    local sign=(--sign "$IDENTITY" --timestamp)
    [ -n "$KEYCHAIN" ] && sign+=(--keychain "$KEYCHAIN")
    productsign "${sign[@]}" "$WORK/$name" "$OUT/$name" >&2
}

# ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: #
### ---------------------- ###
### | The three packages | ###
### ---------------------- ###
suffix=""; [ -n "$IDENTITY" ] || suffix="-UNSIGNED-TEST"
full="macOSLAPS-$VERSION$suffix.pkg"
# The binary is installed first so the LaunchDaemon's postinstall can start it.
product "$full"                                 "macOSLAPS"              com.joshua-d-miller.macoslaps com.joshua-d-miller.macoslaps-check
product "macOSLAPS-Binary-$VERSION$suffix.pkg"  "macOSLAPS (app only)"   com.joshua-d-miller.macoslaps
product "macOSLAPS-LD-$VERSION$suffix.pkg"      "macOSLAPS LaunchDaemon" com.joshua-d-miller.macoslaps-check
echo "$full"

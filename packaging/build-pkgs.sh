#!/bin/bash
# Builds the three macOSLAPS installer packages:
#
#   macOSLAPS-<version>.pkg         app + /etc/paths.d/laps + LaunchDaemon
#   macOSLAPS-Binary-<version>.pkg  app + /etc/paths.d/laps only
#   macOSLAPS-LD-<version>.pkg      LaunchDaemon only
#
# The app installs to /Applications/macOSLAPS.app; /usr/local/laps/macOSLAPS is a
# symlink to its executable through 4.x, so existing scripts and the LaunchDaemon keep
# working.
# Receipts: com.joshua-d-miller.macoslaps (app) and com.joshua-d-miller.macoslaps-check
# (LaunchDaemon). The postinstall scripts forget the 3.x / 845 receipts
# (edu.psu.macOSLAPS, edu.psu.macOSLAPS-check) and remove the old LaunchDaemon.
#
# Usage: build-pkgs.sh <macOSLAPS.app> <version> <outdir> [<Developer ID Installer identity> <keychain>]
# Prints the file name of the full package on the last line.
set -euo pipefail

APP=$1; VERSION=$2; OUT=$3; IDENTITY=${4:-}; KEYCHAIN=${5:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-pkgs.sh: version must look like 4.0.0.846, got '$VERSION'" >&2; exit 1; }
MIN_MACOS=${MIN_MACOS:-13.0}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/components"

# --- component: app ---
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

# --- component: LaunchDaemon ---
root="$WORK/root-daemon"
mkdir -p "$root/Library/LaunchDaemons"
DAEMON=com.joshua-d-miller.macoslaps-check.plist
cp "$REPO/LaunchDaemon/$DAEMON" "$root/Library/LaunchDaemons/"
chmod 644 "$root/Library/LaunchDaemons/$DAEMON"
plutil -lint "$root/Library/LaunchDaemons/$DAEMON" >&2
chmod 755 "$HERE/app-scripts/postinstall" "$HERE/daemon-scripts/preinstall" "$HERE/daemon-scripts/postinstall"
pkgbuild --root "$root" --identifier com.joshua-d-miller.macoslaps-check --version "$VERSION" \
    --scripts "$HERE/daemon-scripts" --install-location / --ownership recommended \
    "$WORK/components/macoslaps-check.pkg" >&2

# --- distributions ---
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

suffix=""; [ -n "$IDENTITY" ] || suffix="-UNSIGNED-TEST"
full="macOSLAPS-$VERSION$suffix.pkg"
# The binary is installed first so the LaunchDaemon's postinstall can start it.
product "$full"                                 "macOSLAPS"              com.joshua-d-miller.macoslaps com.joshua-d-miller.macoslaps-check
product "macOSLAPS-Binary-$VERSION$suffix.pkg"  "macOSLAPS (app only)"   com.joshua-d-miller.macoslaps
product "macOSLAPS-LD-$VERSION$suffix.pkg"      "macOSLAPS LaunchDaemon" com.joshua-d-miller.macoslaps-check
echo "$full"

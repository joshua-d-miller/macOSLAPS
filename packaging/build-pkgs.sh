#!/bin/bash
# Builds the three macOSLAPS installer packages, laid out like every release since 3.x
# so upgrades replace the same receipts and files:
#
#   macOSLAPS-<version>.pkg         binary + /etc/paths.d/laps + LaunchDaemon
#   macOSLAPS-Binary-<version>.pkg  binary + /etc/paths.d/laps only
#   macOSLAPS-LD-<version>.pkg      LaunchDaemon only
#
# Receipts: edu.psu.macOSLAPS (binary) and edu.psu.macOSLAPS-check (LaunchDaemon).
#
# Usage: build-pkgs.sh <binary> <version> <outdir> [<Developer ID Installer identity> <keychain>]
# Prints the file name of the full package on the last line.
set -euo pipefail

BIN=$1; VERSION=$2; OUT=$3; IDENTITY=${4:-}; KEYCHAIN=${5:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-pkgs.sh: version must look like 4.0.0.846, got '$VERSION'" >&2; exit 1; }
MIN_MACOS=${MIN_MACOS:-12.0}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/components"

# --- component: binary ---
root="$WORK/root-binary"
mkdir -p "$root/usr/local/laps" "$root/private/etc/paths.d"
cp "$BIN" "$root/usr/local/laps/macOSLAPS"
cp "$HERE/payload/paths.d-laps" "$root/private/etc/paths.d/laps"
chmod 755 "$root/usr/local/laps" "$root/usr/local/laps/macOSLAPS" "$root/private/etc/paths.d"
chmod 644 "$root/private/etc/paths.d/laps"
pkgbuild --root "$root" --identifier edu.psu.macOSLAPS --version "$VERSION" \
    --install-location / --ownership recommended "$WORK/components/macOSLAPS.pkg" >&2

# --- component: LaunchDaemon ---
root="$WORK/root-daemon"
mkdir -p "$root/Library/LaunchDaemons"
cp "$REPO/LaunchDaemon/edu.psu.macoslaps-check.plist" "$root/Library/LaunchDaemons/"
chmod 644 "$root/Library/LaunchDaemons/edu.psu.macoslaps-check.plist"
plutil -lint "$root/Library/LaunchDaemons/edu.psu.macoslaps-check.plist" >&2
chmod 755 "$HERE/daemon-scripts/preinstall" "$HERE/daemon-scripts/postinstall"
pkgbuild --root "$root" --identifier edu.psu.macOSLAPS-check --version "$VERSION" \
    --scripts "$HERE/daemon-scripts" --install-location / --ownership recommended \
    "$WORK/components/macOSLAPS-check.pkg" >&2

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
        echo "    <pkg-ref id=\"$id\" version=\"$VERSION\" onConclusion=\"none\">${id#edu.psu.}.pkg</pkg-ref>"
    done
    echo '</installer-gui-script>'
}

choice_id() {      # stable choice IDs, matching earlier releases
    case $1 in
        edu.psu.macOSLAPS)       echo installer_choice_1 ;;
        edu.psu.macOSLAPS-check) echo installer_choice_2 ;;
    esac
}
choice_title() {
    case $1 in
        edu.psu.macOSLAPS)       echo "macOSLAPS" ;;
        edu.psu.macOSLAPS-check) echo "LaunchDaemon" ;;
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
product "$full"                                 "macOSLAPS"              edu.psu.macOSLAPS edu.psu.macOSLAPS-check
product "macOSLAPS-Binary-$VERSION$suffix.pkg"  "macOSLAPS (binary only)" edu.psu.macOSLAPS
product "macOSLAPS-LD-$VERSION$suffix.pkg"      "macOSLAPS LaunchDaemon"  edu.psu.macOSLAPS-check
echo "$full"

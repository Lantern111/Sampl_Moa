#!/bin/zsh
# Builds Sampl Moa and writes the two files a GitHub release needs to dist/: the disk image people download, and the
# appcast.xml that tells installed copies about it. Upload both to a release tagged v<version>.
#
# The app gets an ad-hoc signature rather than an Apple Developer ID, so macOS asks people to approve it the first
# time they open it. HowToOpen.txt in the disk image walks them through that.
#
# Build settings can be passed as arguments, such as `MARKETING_VERSION=1.1 CURRENT_PROJECT_VERSION=2`.
# Set RELEASE_URL_PREFIX and RELEASE_OUTPUT_DIR to publish somewhere other than the GitHub release.
set -euo pipefail

root="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
packages="$root/.build/packages"
output_dir="${RELEASE_OUTPUT_DIR:-$root/dist}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# SwiftPM records absolute paths in this file, so it goes stale when the project folder moves. It gets rebuilt.
package_state="$packages/workspace-state.json"
if [[ -f "$package_state" ]] && ! grep -qF "$packages/" "$package_state"; then
    rm "$package_state"
fi

xcodebuild -quiet \
    -project "$root/Sampl Moa.xcodeproj" \
    -scheme "Sampl Moa" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$work/build" \
    -clonedSourcePackagesDirPath "$packages" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "$@" \
    build

app="$work/build/Build/Products/Release/Sampl Moa.app"
codesign --verify --deep --strict "$app"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"

# Runs through python because the installed dmgbuild command stops working when the project folder moves.
tools="$root/.build/dmgtools"
if ! "$tools/bin/python" -c "import dmgbuild" 2>/dev/null; then
    python3 -m venv --clear "$tools"
    "$tools/bin/python" -m pip install --quiet --disable-pip-version-check dmgbuild==1.6.7 ds-store==1.3.3 mac-alias==2.2.3
fi

xcrun swift "$root/Scripts/dmg-background.swift" "$root/Sampl Moa/Assets.xcassets/LogoMark.imageset/logo.svg" "$work"
"$tools/bin/python" -m dmgbuild \
    -s "$root/Scripts/dmg-settings.py" \
    -D app="$app" \
    -D guide="$root/Scripts/HowToOpen.txt" \
    -D background="$work/background.png" \
    "Sampl Moa" \
    "$work/SamplMoa-$version.dmg"

# The copy inside the disk image is the one people get, so check that one too.
mount_point="$work/mount"
mkdir -p "$mount_point"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount_point" "$work/SamplMoa-$version.dmg"
signature_is_valid=true
codesign --verify --deep --strict "$mount_point/Sampl Moa.app" || signature_is_valid=false
hdiutil detach -quiet "$mount_point"
$signature_is_valid

mkdir -p "$output_dir"

# Only the newest version goes in the appcast, so the folder it reads holds just that one disk image.
updates="$work/updates"
mkdir -p "$updates"
cp "$work/SamplMoa-$version.dmg" "$updates/"
prefix="${RELEASE_URL_PREFIX:-https://github.com/Lantern111/Sampl_Moa/releases/download/v$version/}"
"$packages/artifacts/sparkle/Sparkle/bin/generate_appcast" --download-url-prefix "$prefix" "$updates"

mv -f "$updates/SamplMoa-$version.dmg" "$updates/appcast.xml" "$output_dir/"
echo "$output_dir/SamplMoa-$version.dmg"
echo "$output_dir/appcast.xml"

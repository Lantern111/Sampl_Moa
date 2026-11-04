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

image="$work/image"
mkdir -p "$image"
ditto "$app" "$image/Sampl Moa.app"
ln -s /Applications "$image/Applications"
cp "$root/Scripts/HowToOpen.txt" "$image/처음 여는 방법 - How to Open.txt"

mkdir -p "$output_dir"
hdiutil create -quiet -ov -volname "Sampl Moa" -srcfolder "$image" -fs APFS -format ULFO "$work/SamplMoa-$version.dmg"

# Only the newest version goes in the appcast, so the folder it reads holds just that one disk image.
updates="$work/updates"
mkdir -p "$updates"
cp "$work/SamplMoa-$version.dmg" "$updates/"
prefix="${RELEASE_URL_PREFIX:-https://github.com/Lantern111/Sampl_Moa/releases/download/v$version/}"
"$packages/artifacts/sparkle/Sparkle/bin/generate_appcast" --download-url-prefix "$prefix" "$updates"

mv -f "$updates/SamplMoa-$version.dmg" "$updates/appcast.xml" "$output_dir/"
echo "$output_dir/SamplMoa-$version.dmg"
echo "$output_dir/appcast.xml"

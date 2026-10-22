#!/bin/sh
set -eu
umask 022

usage() {
  cat <<'HELP'
Build a portable, Developer ID-signed installer on this Mac.

Usage: CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
       ./Scripts/build-portable-installer.sh [--arch universal|arm64|x86_64] [--output DIRECTORY]

The default builds for both Apple Silicon and Intel. The destination Mac needs
macOS 13 or later, but does not need Xcode, Swift or your signing certificate.
Set NOTARIZATION_PROFILE to your own notarytool keychain profile to notarize
with Apple and attach its approval to the installer. Nothing is published.
HELP
}
fail() { printf '%s\n' "$*" >&2; exit 1; }
package_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
architecture=universal
output_dir="$package_root/artifacts"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --arch) [ "$#" -ge 2 ] || fail '--arch needs a value.'; architecture=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || fail '--output needs a directory.'; output_dir=$2; shift 2 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done
case "$architecture" in universal) architectures='arm64 x86_64' ;; arm64|x86_64) architectures=$architecture ;; *) fail 'Choose universal, arm64 or x86_64.' ;; esac
[ -n "${CODESIGN_IDENTITY:-}" ] || fail 'Set CODESIGN_IDENTITY to your Developer ID Application certificate. See docs/PORTABLE-INSTALLER.md.'
for tool in swift xcrun codesign ditto shasum plutil; do command -v "$tool" >/dev/null 2>&1 || fail "Required development tool not found: $tool"; done
mkdir -p "$output_dir"
output_dir="$(CDPATH= cd -- "$output_dir" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/Xeneon-portable.XXXXXX")"
archive_stage=
cleanup() { rm -rf "$scratch"; if [ -n "$archive_stage" ]; then rm -rf "$archive_stage"; fi; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
folder_name="MacXeneonEdgeTouchDriver-Installer-$architecture"
folder="$scratch/$folder_name"
app="$folder/Install Xeneon Touch.app"
resources="$app/Contents/Resources"
helpers="$app/Contents/Helpers"
mkdir -p "$resources/Scripts" "$helpers" "$app/Contents/MacOS"
sdk="$(xcrun --sdk macosx --show-sdk-path)"

for arch in $architectures; do
  echo "Building for $arch..."
  swift build --package-path "$package_root" --scratch-path "$scratch/build" -c release --arch "$arch" --product MacXeneonEdgeTouchDriver \
    -Xswiftc -file-prefix-map -Xswiftc "$package_root=/Source/MacXeneonEdgeTouchDriver" \
    -Xswiftc -file-prefix-map -Xswiftc "$HOME=/SourceHome" \
    -Xswiftc -debug-prefix-map -Xswiftc "$package_root=/Source/MacXeneonEdgeTouchDriver" \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/SourceHome" \
    -Xswiftc -debug-prefix-map -Xswiftc "$scratch=/Build"
  bin_path="$(swift build --package-path "$package_root" --scratch-path "$scratch/build" -c release --arch "$arch" --show-bin-path)"
  mkdir -p "$scratch/$arch"
  cp "$bin_path/MacXeneonEdgeTouchDriver" "$scratch/$arch/MacXeneonEdgeTouchDriver"
  for name in PrepareInstall XeneonTouchInstaller; do
    case "$name" in PrepareInstall) source_file="$package_root/Scripts/prepare-install.swift" ;; *) source_file="$package_root/Scripts/PortableInstaller.swift" ;; esac
    xcrun swiftc -O -target "$arch-apple-macosx13.0" -sdk "$sdk" \
      -file-prefix-map "$package_root=/Source/MacXeneonEdgeTouchDriver" -file-prefix-map "$HOME=/SourceHome" \
      -debug-prefix-map "$package_root=/Source/MacXeneonEdgeTouchDriver" -debug-prefix-map "$HOME=/SourceHome" \
      "$source_file" -o "$scratch/$arch/$name"
  done
done

for name in MacXeneonEdgeTouchDriver PrepareInstall XeneonTouchInstaller; do
  case "$name" in XeneonTouchInstaller) destination="$app/Contents/MacOS/$name" ;; *) destination="$helpers/$name" ;; esac
  if [ "$architecture" = universal ]; then
    xcrun lipo -create "$scratch/arm64/$name" "$scratch/x86_64/$name" -output "$destination"
  else cp "$scratch/$architecture/$name" "$destination"; fi
  xcrun strip -S "$destination"
  chmod 755 "$destination"
done
cp "$package_root/Resources/PortableInstaller/Info.plist" "$app/Contents/Info.plist"
cp "$package_root/Scripts/install.sh" "$package_root/Scripts/uninstall.sh" "$resources/Scripts/"
cp "$package_root/Resources/com.ajvwhite.MacXeneonEdgeTouchDriver.plist.template" "$resources/"
cp "$package_root/Resources/PortableInstaller/START-HERE.txt" "$resources/START HERE.txt"
cp "$package_root/LICENSE" "$resources/LICENSE.txt"
cp "$resources/START HERE.txt" "$folder/START HERE.txt"

# Check before signing or sending code to Apple, not only before packaging.
for binary in "$helpers/MacXeneonEdgeTouchDriver" "$helpers/PrepareInstall" "$app/Contents/MacOS/XeneonTouchInstaller"; do
  /usr/bin/strings -a "$binary" > "$scratch/binary-strings.txt"
  for private_root in "$HOME" "$package_root" "$scratch"; do
    if /usr/bin/grep -F "$private_root/" "$scratch/binary-strings.txt" >/dev/null; then
      fail 'A development path remains in a binary. No code was submitted to Apple and no portable archive was created.'
    fi
  done
done

# Sign each executable, then the containing app. Never export private keys.
for entry in "$helpers/MacXeneonEdgeTouchDriver" "$helpers/PrepareInstall"; do
  case "$entry" in */PrepareInstall) identifier=MacXeneonEdgeTouchDriver.PrepareInstall ;; *) identifier=MacXeneonEdgeTouchDriver ;; esac
  codesign --force --options runtime --timestamp --identifier "$identifier" --sign "$CODESIGN_IDENTITY" "$entry"
  codesign --verify --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$entry"
done
notarize() {
  notary_archive=$1
  notary_round=$2
  xcrun notarytool submit "$notary_archive" --keychain-profile "$NOTARIZATION_PROFILE" --wait --output-format json > "$scratch/$notary_round.json"
  status="$(plutil -extract status raw -o - "$scratch/$notary_round.json")"
  [ "$status" = Accepted ] || fail "Apple did not accept the $notary_round submission. No portable archive was published to the output directory."
}
# Custom installers need the installed code notarized before the installer.
# Standalone command-line tools have online tickets; Apple cannot staple them.
if [ -n "${NOTARIZATION_PROFILE:-}" ]; then
  echo 'Submitting the signed driver and preparation tool to Apple...'
  ditto --norsrc -c -k --keepParent "$helpers" "$scratch/payload.zip"
  notarize "$scratch/payload.zip" payload
fi
codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$app"
codesign --verify --deep --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
archive_stage="$(mktemp -d "$output_dir/.portable.XXXXXX")"
archive="$archive_stage/$folder_name.zip"
ditto --norsrc -c -k --keepParent "$folder" "$archive"
if [ -n "${NOTARIZATION_PROFILE:-}" ]; then
  echo 'Submitting the signed installer to Apple for notarization...'
  notarize "$archive" installer
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  rm -f "$archive"
  ditto --norsrc -c -k --keepParent "$folder" "$archive"
  /usr/sbin/spctl --assess --type execute "$app"
else
  echo 'Signed only: Apple notarization was not requested. This is not a notarized distribution.'
fi
(cd "$archive_stage" && shasum -a 256 "$folder_name.zip" > "$folder_name.zip.sha256")
mv -f "$archive" "$output_dir/$folder_name.zip"
mv -f "$archive_stage/$folder_name.zip.sha256" "$output_dir/$folder_name.zip.sha256"
printf '\nPortable installer: %s\nChecksum: %s\nNothing was installed or published. Private signing keys, notarization credentials and local settings were not copied. Public signing certificates are included in signatures.\n' "$output_dir/$folder_name.zip" "$output_dir/$folder_name.zip.sha256"

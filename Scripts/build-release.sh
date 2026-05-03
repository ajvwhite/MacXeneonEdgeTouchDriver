#!/bin/sh
set -eu

binary_name="MacXeneonEdgeTouchDriver"
package_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
binary_path="${package_root}/.build/release/${binary_name}"
artifacts_dir="${package_root}/artifacts"
archive_path="${artifacts_dir}/${binary_name}.zip"

echo "Building ${binary_name} in release mode..."
swift build -c release --package-path "$package_root"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "Signing with Developer ID identity: ${CODESIGN_IDENTITY}"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$binary_path"
else
  echo "Signing ad hoc. Set CODESIGN_IDENTITY to use Developer ID signing."
  codesign --force --sign - "$binary_path"
fi

codesign --verify --strict --verbose=2 "$binary_path"

mkdir -p "$artifacts_dir"
ditto -c -k --keepParent "$binary_path" "$archive_path"
echo "Release archive: ${archive_path}"

if [ -n "${NOTARIZATION_PROFILE:-}" ]; then
  echo "Submitting for notarization with keychain profile: ${NOTARIZATION_PROFILE}"
  xcrun notarytool submit "$archive_path" --keychain-profile "$NOTARIZATION_PROFILE" --wait
else
  echo "Skipping notarization. Set NOTARIZATION_PROFILE to submit the archive."
fi

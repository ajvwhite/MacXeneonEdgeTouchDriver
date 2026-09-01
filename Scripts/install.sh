#!/bin/sh
set -eu

label="com.ajvwhite.MacXeneonEdgeTouchDriver"
binary_name="MacXeneonEdgeTouchDriver"
package_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
app_support_dir="${HOME}/Library/Application Support/MacXeneonEdgeTouchDriver"
bin_dir="${app_support_dir}/bin"
log_dir="${HOME}/Library/Logs/MacXeneonEdgeTouchDriver"
launch_agents_dir="${HOME}/Library/LaunchAgents"
plist_template="${package_root}/Resources/com.ajvwhite.MacXeneonEdgeTouchDriver.plist.template"
plist_path="${launch_agents_dir}/${label}.plist"
installed_binary="${bin_dir}/${binary_name}"
config_path="${app_support_dir}/config.json"
driver_log_path="${log_dir}/driver.log"
uid="$(id -u)"
codesign_identity="${CODESIGN_IDENTITY:-}"
codesign_description="linker ad hoc signature"
if [ -n "$codesign_identity" ]; then
  codesign_description="$codesign_identity"
fi

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift toolchain not found. Install Xcode or Command Line Tools, then rerun this script." >&2
  exit 1
fi

if [ ! -f "$plist_template" ]; then
  echo "LaunchAgent template not found: ${plist_template}" >&2
  exit 1
fi

echo "Building ${binary_name} in release mode..."
swift build -c release --package-path "$package_root"

mkdir -p "$bin_dir" "$log_dir" "$launch_agents_dir"
install -m 755 "${package_root}/.build/release/${binary_name}" "$installed_binary"
if [ -n "$codesign_identity" ]; then
  if ! command -v codesign >/dev/null 2>&1; then
    echo "codesign not found, but CODESIGN_IDENTITY was supplied." >&2
    exit 1
  fi
  codesign \
    --force \
    --sign "$codesign_identity" \
    --identifier "$label" \
    --timestamp=none \
    "$installed_binary"
fi
touch "${log_dir}/stdout.log" "${log_dir}/stderr.log" "$driver_log_path"

if [ ! -f "$config_path" ]; then
  cat > "$config_path" <<EOF
{
  "logLevel": "info",
  "timing": {
    "warpToClickDelayMs": 10,
    "downToUpDelayMs": 20,
    "clickToWarpBackDelayMs": 10,
    "tapDebounceMs": 50,
    "stuckGestureTimeoutMs": 2000
  },
  "display": {
    "vendorNumber": 3672,
    "modelNumber": 60672,
    "serialNumber": null,
    "expectedWidth": 2560,
    "expectedHeight": 720
  },
  "gesture": {
    "multiTouchEnabled": false,
    "holdToDragMs": 300,
    "movementThresholdPoints": 8,
    "scrollSensitivity": 1.0,
    "doubleClickDistancePoints": 12
  },
  "diagnostics": {
    "fileLogPath": "${driver_log_path}",
    "fileLogMaxBytes": 5242880
  }
}
EOF
fi

escaped_binary="$(escape_sed_replacement "$installed_binary")"
escaped_log_dir="$(escape_sed_replacement "$log_dir")"
sed \
  -e "s/__BIN_PATH__/${escaped_binary}/g" \
  -e "s/__LOG_DIR__/${escaped_log_dir}/g" \
  "$plist_template" > "$plist_path"

launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
attempt=1
while ! launchctl bootstrap "gui/${uid}" "$plist_path"; do
  if [ "$attempt" -ge 5 ]; then
    echo "Could not bootstrap ${label} after ${attempt} attempts." >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done
launchctl enable "gui/${uid}/${label}" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true

cat <<EOF
Installed ${binary_name}.

LaunchAgent:
  ${plist_path}

Binary:
  ${installed_binary}

Code signing:
  ${codesign_description}

Logs:
  ${log_dir}
  ${driver_log_path}

LaunchAgent stdout/stderr:
  ${log_dir}/stdout.log
  ${log_dir}/stderr.log

Grant macOS permissions to the installed binary, or to the app that launches it if macOS attributes permissions there:
  - Input Monitoring
  - Accessibility

Config file location:
  ${config_path}
EOF

#!/bin/sh
set -eu

label="com.ajvwhite.MacXeneonEdgeTouchDriver"
binary_name="MacXeneonEdgeTouchDriver"
app_support_dir="${HOME}/Library/Application Support/MacXeneonEdgeTouchDriver"
launch_agents_dir="${HOME}/Library/LaunchAgents"
plist_path="${launch_agents_dir}/${label}.plist"
log_dir="${HOME}/Library/Logs/MacXeneonEdgeTouchDriver"
uid="$(id -u)"

launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
if [ -f "$plist_path" ]; then
  launchctl bootout "gui/${uid}" "$plist_path" >/dev/null 2>&1 || true
fi

rm -f "$plist_path"
rm -rf "$app_support_dir"

cat <<EOF
Uninstalled ${binary_name}.

Removed:
  ${plist_path}
  ${app_support_dir}

Kept logs:
  ${log_dir}

Remove Privacy & Security entries manually if you no longer want macOS to remember prior permissions.
EOF

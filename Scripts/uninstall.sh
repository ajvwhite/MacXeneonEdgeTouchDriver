#!/bin/sh
set -eu

label="com.ajvwhite.MacXeneonEdgeTouchDriver"
binary_name="MacXeneonEdgeTouchDriver"
app_support_dir="${HOME}/Library/Application Support/MacXeneonEdgeTouchDriver"
launch_agents_dir="${HOME}/Library/LaunchAgents"
plist_path="${launch_agents_dir}/${label}.plist"
log_dir="${HOME}/Library/Logs/MacXeneonEdgeTouchDriver"
uid="$(id -u)"
domain="gui/${uid}"
service="${domain}/${label}"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

# Match install.sh's service-not-found convention, not human-readable output.
# A missing/inaccessible GUI domain and all other query errors remain unknown.
# These observations establish registration state, not synchronous process exit.
job_state() {
  if launchctl print "$domain" >/dev/null; then
    :
  else
    query_status=$?
    printf 'Cannot query the GUI domain (launchctl status %s).\n' "$query_status" >&2
    return 2
  fi
  if query_error="$(launchctl print "$service" 2>&1 >/dev/null)"; then
    return 0
  else
    query_status=$?
    if [ "$query_status" -eq 113 ]; then
      return 1
    fi
    printf '%s\n' "$query_error" >&2
    printf 'Cannot determine LaunchAgent state (launchctl status %s).\n' "$query_status" >&2
    return 2
  fi
}

if job_state; then
  if ! launchctl bootout "$service"; then
    fail 'Uninstall stopped: launchd did not confirm removal of the job; installation files were not removed.'
  fi
else
  state_status=$?
  [ "$state_status" -eq 1 ] || fail 'Uninstall stopped: LaunchAgent state is unknown; installation files were not removed.'
fi

# Do not remove files if the job stayed registered, reappeared, or cannot be
# queried after bootout (or after the initially absent observation).
if job_state; then
  fail 'Uninstall stopped: the LaunchAgent is registered; installation files were not removed.'
else
  state_status=$?
  [ "$state_status" -eq 1 ] || fail 'Uninstall stopped: could not verify LaunchAgent removal; installation files were not removed.'
fi

rm -f "$plist_path" || fail "Uninstall incomplete: could not remove ${plist_path}; Application Support files were not removed."
rm -rf "$app_support_dir" || fail "Uninstall incomplete: ${app_support_dir} may have been partially removed."

cat <<EOF
Uninstalled ${binary_name}.
The LaunchAgent was verified unregistered before removing files.
Process exit and manually started copies have not been checked.

Removed:
  ${plist_path}
  ${app_support_dir}

Kept logs:
  ${log_dir}

Remove Privacy & Security entries manually if you no longer want macOS to remember prior permissions.
EOF

#!/bin/sh
set -eu
umask 077

label="com.ajvwhite.MacXeneonEdgeTouchDriver"
binary_name="MacXeneonEdgeTouchDriver"
package_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
app_support_dir="${HOME}/Library/Application Support/MacXeneonEdgeTouchDriver"
bin_dir="${app_support_dir}/bin"
log_dir="${HOME}/Library/Logs/MacXeneonEdgeTouchDriver"
launch_agents_dir="${HOME}/Library/LaunchAgents"
plist_template="${package_root}/Resources/${label}.plist.template"
plist_path="${launch_agents_dir}/${label}.plist"
installed_binary="${bin_dir}/${binary_name}"
config_path="${app_support_dir}/config.json"
uid="$(id -u)"
domain="gui/${uid}"
service="${domain}/${label}"
lock_dir="${app_support_dir}/.install-lock"
stage_dir=
bin_stage=
plist_stage=
config_stage=
backup_dir=
lock_acquired=0
rollback_needed=0
activation_attempted=0
old_loaded=0
had_binary=0
had_plist=0
had_config=0
binary_changed=0
plist_changed=0
config_changed=0

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

# Only the service-not-found status means absent. Other query failures abort.
# Do not parse launchctl's human-readable output as a stable API.
job_state() {
  if launchctl print "$service" > "$stage_dir/job-state.txt" 2> "$stage_dir/job-error.txt"; then
    return 0
  else
    query_status=$?
    if [ "$query_status" -eq 113 ]; then
      return 1
    fi
    cat "$stage_dir/job-error.txt" >&2
    printf 'Cannot determine LaunchAgent state (launchctl status %s).\n' "$query_status" >&2
    return 2
  fi
}

restore_file() {
  target=$1
  previous=$2
  existed=$3
  if [ "$existed" -eq 1 ]; then
    mv -f "$previous" "$target"
  else
    rm -f "$target"
  fi
}

rollback() {
  printf 'Installation failed; attempting rollback. Prior files: %s\n' "$backup_dir" >&2
  prior_still_loaded=0
  if [ "$activation_attempted" -eq 1 ]; then
    # A failed bootstrap can still have registered a service. Stop it before
    # restoring files so KeepAlive cannot restart it during recovery.
    if job_state; then
      if ! launchctl bootout "$service"; then
        printf 'Rollback incomplete: could not unload the replacement job; files were not restored.\n' >&2
        return 1
      fi
    else
      state_status=$?
      if [ "$state_status" -ne 1 ]; then
        printf 'Rollback incomplete: job state is unknown; files were not restored.\n' >&2
        return 1
      fi
    fi
  elif [ "$old_loaded" -eq 1 ]; then
    if job_state; then
      if [ "$binary_changed" -eq 1 ] || [ "$plist_changed" -eq 1 ] || [ "$config_changed" -eq 1 ]; then
        printf 'Rollback incomplete: a job was registered again during replacement; files were not restored.\n' >&2
        return 1
      fi
      # The initial bootout failed without removing the old job. No files
      # have been published at this point.
      prior_still_loaded=1
    else
      state_status=$?
      if [ "$state_status" -ne 1 ]; then
        printf 'Rollback incomplete: cannot determine whether the prior job is still registered.\n' >&2
        return 1
      fi
    fi
  fi

  restore_failed=0
  if [ "$binary_changed" -eq 1 ]; then
    restore_file "$installed_binary" "$bin_stage/previous-binary" "$had_binary" || restore_failed=1
  fi
  if [ "$plist_changed" -eq 1 ]; then
    restore_file "$plist_path" "$plist_stage/previous-plist" "$had_plist" || restore_failed=1
  fi
  if [ "$config_changed" -eq 1 ]; then
    # An existing config is never replaced, even during rollback.
    rm -f "$config_path" || restore_failed=1
  fi
  if [ "$restore_failed" -eq 1 ]; then
    printf 'Rollback incomplete: one or more files could not be restored; prior job was not restarted.\n' >&2
    return 1
  fi
  printf 'Rollback restored the prior installed files (including prior absence).\n' >&2
  if [ "$old_loaded" -eq 1 ] && [ "$prior_still_loaded" -eq 0 ]; then
    if ! launchctl bootstrap "$domain" "$plist_path"; then
      printf 'Rollback incomplete: files restored, but launchd did not accept the prior job.\n' >&2
      return 1
    fi
    printf 'launchd accepted the prior job again; continued operation has not been checked.\n' >&2
  elif [ "$prior_still_loaded" -eq 1 ]; then
    printf 'The prior job is still registered; continued operation has not been checked.\n' >&2
  else
    printf 'No prior job was registered; rollback left it unregistered.\n' >&2
  fi
}

cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$rollback_needed" -eq 1 ]; then
    if ! rollback; then
      printf 'Manual recovery is required. Backups remain at: %s\n' "$backup_dir" >&2
    fi
    result=1
  fi
  for scratch in "$stage_dir" "$bin_stage" "$plist_stage" "$config_stage"; do
    if [ -n "$scratch" ]; then
      rm -rf "$scratch" || printf 'Could not remove staging directory: %s\n' "$scratch" >&2
    fi
  done
  if [ "$lock_acquired" -eq 1 ]; then
    rmdir "$lock_dir" || printf 'Could not remove installer lock: %s\n' "$lock_dir" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

case "$HOME" in
  /*) ;;
  *) fail 'HOME must be an absolute path.' ;;
esac
for tool in swift launchctl plutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  command -v codesign >/dev/null 2>&1 || fail 'codesign not found.'
fi
[ -f "$plist_template" ] || fail "LaunchAgent template not found: $plist_template"

# Refuse targets whose replacement semantics differ from regular files.
for target in "$installed_binary" "$config_path" "$plist_path"; do
  if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
    fail "Expected a regular file or an absent path: $target"
  fi
done
for directory in "$app_support_dir" "$bin_dir" "$launch_agents_dir" "$log_dir" "$app_support_dir/install-backups"; do
  [ ! -L "$directory" ] || fail "Refusing a symbolic-link installation directory: $directory"
done
mkdir -p "$app_support_dir"
mkdir "$lock_dir" || fail "Another installer may be running. Check before removing: $lock_dir"
lock_acquired=1
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/Xeneon-install.XXXXXX")"

echo "Building ${binary_name} in release mode..."
swift build -c release --package-path "$package_root"
install -m 755 "${package_root}/.build/release/${binary_name}" "$stage_dir/binary"
[ -s "$stage_dir/binary" ] && [ -x "$stage_dir/binary" ] || fail 'The staged executable is empty or not executable.'

# CODESIGN_IDENTITY follows isleofgreg's interface from PR #4. Both signing
# and verification happen before replacing any installed file.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$stage_dir/binary"
  codesign --verify --strict "$stage_dir/binary"
fi
swift "$package_root/Scripts/prepare-install.swift" "$plist_template" "$stage_dir" "$installed_binary" "$config_path" "$log_dir"
plutil -lint -- "$stage_dir/agent.plist"

# Prepare destination directories, retained backups and same-filesystem rename
# sources before stopping the job. Existing log files are not truncated/touched.
mkdir -p "$bin_dir" "$log_dir" "$launch_agents_dir" "$app_support_dir/install-backups"
backup_dir="$(mktemp -d "$app_support_dir/install-backups/transaction.XXXXXX")"
bin_stage="$(mktemp -d "$bin_dir/.install.XXXXXX")"
plist_stage="$(mktemp -d "$launch_agents_dir/.xeneon-install.XXXXXX")"
config_stage="$(mktemp -d "$app_support_dir/.install.XXXXXX")"
if [ -f "$installed_binary" ]; then
  had_binary=1
  cp -p "$installed_binary" "$backup_dir/binary"
  cp -p "$backup_dir/binary" "$bin_stage/previous-binary"
fi
if [ -f "$plist_path" ]; then
  had_plist=1
  cp -p "$plist_path" "$backup_dir/agent.plist"
  cp -p "$backup_dir/agent.plist" "$plist_stage/previous-plist"
fi
if [ -f "$config_path" ]; then
  had_config=1
  cp -p "$config_path" "$backup_dir/config.json"
  cmp -s "$config_path" "$stage_dir/config.json" || fail 'Config changed during preflight; rerun the installer.'
fi
install -m 755 "$stage_dir/binary" "$bin_stage/next-binary"
install -m 644 "$stage_dir/agent.plist" "$plist_stage/next-plist"
if [ "$had_config" -eq 0 ]; then
  install -m 600 "$stage_dir/config.json" "$config_stage/next-config"
fi
launchctl print "$domain" > "$stage_dir/domain-state.txt"
if job_state; then
  old_loaded=1
  [ "$had_binary" -eq 1 ] && [ "$had_plist" -eq 1 ] || fail 'A job is registered, but its installed binary or plist is missing; cannot prepare rollback.'
  plutil -lint -- "$backup_dir/agent.plist"
  plutil -extract Label raw -expect string -n -o "$stage_dir/prior-label" -- "$backup_dir/agent.plist"
  printf '%s' "$label" > "$stage_dir/expected-label"
  cmp -s "$stage_dir/prior-label" "$stage_dir/expected-label" || fail 'The prior plist has an unexpected Label; cannot prepare rollback.'
else
  state_status=$?
  [ "$state_status" -eq 1 ] || fail 'LaunchAgent preflight query failed.'
fi
printf 'binary=%s\nplist=%s\nconfig=%s\njob_registered=%s\n' "$had_binary" "$had_plist" "$had_config" "$old_loaded" > "$backup_dir/state.txt"

# From here failures require recovery. These renames are atomic per file only;
# the set of files and launchd state cannot be committed atomically together.
rollback_needed=1
if [ "$old_loaded" -eq 1 ]; then
  launchctl bootout "$service"
fi
binary_changed=1
mv -f "$bin_stage/next-binary" "$installed_binary"
plist_changed=1
mv -f "$plist_stage/next-plist" "$plist_path"
if [ "$had_config" -eq 0 ]; then
  config_changed=1
  mv -f "$config_stage/next-config" "$config_path"
fi
activation_attempted=1
# RunAtLoad starts the job. Leave persistent enable/disable overrides alone.
launchctl bootstrap "$domain" "$plist_path"
rollback_needed=0

cat <<EOF_RESULT
Installed ${binary_name}. launchd accepted the new job.
Continued daemon operation and macOS permissions have not been checked.

Binary: ${installed_binary}
LaunchAgent: ${plist_path}
Config: ${config_path}
Logs: ${log_dir}
Prior files and registration state: ${backup_dir}
EOF_RESULT

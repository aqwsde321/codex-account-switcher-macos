#!/bin/zsh
set -eu

project_dir=${0:A:h:h}
source_app="$project_dir/.build/CodexAccountSwitcher.app"
target_app="$HOME/Applications/CodexAccountSwitcher.app"
target_binary="$target_app/Contents/MacOS/CodexAccountMenuBar"
sleep_guard_source="$source_app/Contents/Helpers/CodexSleepGuard"
sleep_guard_target="/Library/PrivilegedHelperTools/local.codex.account-switcher.sleep-guard"
sleep_guard_template="$project_dir/Scripts/CodexSleepGuard-LaunchDaemon.plist"
sleep_guard_plist="/Library/LaunchDaemons/local.codex.account-switcher.sleep-guard.plist"
agent_dir="$HOME/Library/LaunchAgents"
agent_path="$agent_dir/local.codex.account-switcher.plist"
log_dir="$HOME/Library/Logs"
label=local.codex.account-switcher
gui_target="gui/$(id -u)"
service_target="$gui_target/$label"
sleep_guard_label=local.codex.account-switcher.sleep-guard
sleep_guard_service_target="system/$sleep_guard_label"
install_uid=$(id -u)
expected_program_line=$'\tprogram = '"$target_binary"
expected_running_line=$'\tstate = running'
expected_sleep_guard_program_line=$'\tprogram = '"$sleep_guard_target"
sleep_guard_plist_temp=""

cleanup() {
    if [[ -n "$sleep_guard_plist_temp" ]]; then
        rm -f "$sleep_guard_plist_temp"
    fi
}

trap cleanup EXIT

target_is_running() {
    local pid executable process_list
    if ! process_list=$(ps -axo pid=,comm=); then
        print -u2 -- "error=process_inspection_failed"
        exit 1
    fi
    while read -r pid executable; do
        [[ "$executable" == "$target_binary" ]] && return 0
    done <<< "$process_list"
    return 1
}

service_is_running() {
    local service_state service_pid service_executable
    service_state=$(launchctl print "$service_target" 2>/dev/null) || return 1
    grep -Fqx -- "$expected_program_line" <<< "$service_state" || return 1
    grep -Fqx -- "$expected_running_line" <<< "$service_state" || return 1
    service_pid=$(awk '$1 == "pid" && $2 == "=" { print $3; exit }' <<< "$service_state")
    [[ -n "$service_pid" ]] || return 1
    service_executable=$(ps -p "$service_pid" -o comm= 2>/dev/null) || return 1
    [[ "$service_executable" == "$target_binary" ]]
}

sleep_guard_service_is_running() {
    local service_state service_pid service_executable
    service_state=$(launchctl print "$sleep_guard_service_target" 2>/dev/null) || return 1
    grep -Fqx -- "$expected_sleep_guard_program_line" <<< "$service_state" || return 1
    grep -Fqx -- "$expected_running_line" <<< "$service_state" || return 1
    service_pid=$(awk '$1 == "pid" && $2 == "=" { print $3; exit }' <<< "$service_state")
    [[ -n "$service_pid" ]] || return 1
    service_executable=$(ps -p "$service_pid" -o comm= 2>/dev/null) || return 1
    [[ "$service_executable" == "$sleep_guard_target" ]]
}

code_identifier() {
    codesign -d --verbose=4 "$1" 2>&1 \
        | awk -F= '$1 == "Identifier" { print $2; exit }'
}

run_as_admin() {
    /usr/bin/osascript - "$@" <<'APPLESCRIPT'
on run arguments
    set commandText to ""
    repeat with argumentText in arguments
        if commandText is not "" then set commandText to commandText & " "
        set commandText to commandText & quoted form of (argumentText as text)
    end repeat
    do shell script commandText with administrator privileges
end run
APPLESCRIPT
}

if [[ -L "$target_app" || -L "$agent_path" || -L "$sleep_guard_target" \
    || -L "$sleep_guard_plist" ]]; then
    print -u2 -- "error=unsafe_install_target reason=symlink"
    exit 1
fi

if [[ -e "$target_app" ]]; then
    if ! existing_bundle_id=$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist" 2>/dev/null); then
        print -u2 -- "error=unsafe_install_target reason=unknown_bundle"
        exit 1
    fi
    if [[ "$existing_bundle_id" != "$label" ]]; then
        print -u2 -- "error=unsafe_install_target reason=bundle_id_mismatch"
        exit 1
    fi
fi

if [[ -e "$agent_path" ]]; then
    if ! existing_agent_label=$(plutil -extract Label raw "$agent_path" 2>/dev/null) \
        || ! existing_agent_program=$(plutil -extract ProgramArguments.0 raw "$agent_path" 2>/dev/null); then
        print -u2 -- "error=unsafe_install_target reason=unknown_launch_agent"
        exit 1
    fi
    if [[ "$existing_agent_label" != "$label" || "$existing_agent_program" != "$target_binary" ]]; then
        print -u2 -- "error=unsafe_install_target reason=launch_agent_mismatch"
        exit 1
    fi
fi

if [[ -e "$sleep_guard_target" || -e "$sleep_guard_plist" ]]; then
    if [[ ! -f "$sleep_guard_target" || ! -f "$sleep_guard_plist" ]]; then
        print -u2 -- "error=unsafe_sleep_guard_target reason=incomplete_install"
        exit 1
    fi
    if ! existing_sleep_guard_label=$(plutil -extract Label raw "$sleep_guard_plist" 2>/dev/null) \
        || ! existing_sleep_guard_program=$(plutil -extract ProgramArguments.0 raw "$sleep_guard_plist" 2>/dev/null) \
        || ! existing_sleep_guard_uid=$(plutil -extract ProgramArguments.1 raw "$sleep_guard_plist" 2>/dev/null); then
        print -u2 -- "error=unsafe_sleep_guard_target reason=invalid_plist"
        exit 1
    fi
    existing_sleep_guard_arguments_valid=true
    if existing_sleep_guard_extra=$(
        plutil -extract ProgramArguments.2 raw "$sleep_guard_plist" 2>/dev/null
    ); then
        [[ "$existing_sleep_guard_extra" == "__INSTALL_UID__" ]] \
            || existing_sleep_guard_arguments_valid=false
    fi
    if plutil -extract ProgramArguments.3 raw "$sleep_guard_plist" >/dev/null 2>&1; then
        existing_sleep_guard_arguments_valid=false
    fi
    if [[ "$existing_sleep_guard_label" != "$sleep_guard_label" \
        || "$existing_sleep_guard_program" != "$sleep_guard_target" \
        || "$existing_sleep_guard_uid" != "$install_uid" \
        || "$existing_sleep_guard_arguments_valid" != true \
        || $(stat -f '%Su:%Sg:%OLp' "$sleep_guard_target") != root:wheel:755 \
        || $(stat -f '%Su:%Sg:%OLp' "$sleep_guard_plist") != root:wheel:644 \
        || $(code_identifier "$sleep_guard_target") != "$sleep_guard_label" ]]; then
        print -u2 -- "error=unsafe_sleep_guard_target reason=identity_mismatch"
        exit 1
    fi
fi

if sleep_guard_state=$(launchctl print "$sleep_guard_service_target" 2>/dev/null); then
    if [[ ! -e "$sleep_guard_plist" ]]; then
        print -u2 -- "error=unsafe_sleep_guard_target reason=unmanaged_service"
        exit 1
    fi
    if ! grep -Fqx -- "$expected_sleep_guard_program_line" <<< "$sleep_guard_state"; then
        print -u2 -- "error=unsafe_sleep_guard_target reason=loaded_program_mismatch"
        exit 1
    fi
    if grep -Fqx -- "$expected_running_line" <<< "$sleep_guard_state" \
        && ! sleep_guard_service_is_running; then
        print -u2 -- "error=unsafe_sleep_guard_target reason=loaded_process_mismatch"
        exit 1
    fi
fi

if service_state=$(launchctl print "$service_target" 2>/dev/null); then
    if [[ ! -e "$agent_path" ]]; then
        print -u2 -- "error=unsafe_install_target reason=unmanaged_launch_agent"
        exit 1
    fi
    if ! grep -Fqx -- "$expected_program_line" <<< "$service_state"; then
        print -u2 -- "error=unsafe_install_target reason=loaded_program_mismatch"
        exit 1
    fi
    if grep -Fqx -- "$expected_running_line" <<< "$service_state" && ! service_is_running; then
        print -u2 -- "error=unsafe_install_target reason=loaded_process_mismatch"
        exit 1
    fi
fi

"$project_dir/Scripts/build-app.sh"

if [[ ! -x "$sleep_guard_source" \
    || $(code_identifier "$sleep_guard_source") != "$sleep_guard_label" ]]; then
    print -u2 -- "error=invalid_bundled_sleep_guard"
    exit 1
fi

sleep_guard_plist_temp=$(mktemp "${TMPDIR:-/tmp}/codex-sleep-guard.plist.XXXXXX")
install -m 600 "$sleep_guard_template" "$sleep_guard_plist_temp"
plutil -remove ProgramArguments.1 "$sleep_guard_plist_temp"
plutil -insert ProgramArguments.1 -string "$install_uid" "$sleep_guard_plist_temp"
plutil -lint "$sleep_guard_plist_temp"
if [[ $(plutil -extract ProgramArguments.0 raw "$sleep_guard_plist_temp") \
        != "$sleep_guard_target" \
    || $(plutil -extract ProgramArguments.1 raw "$sleep_guard_plist_temp") \
        != "$install_uid" ]] \
    || plutil -extract ProgramArguments.2 raw "$sleep_guard_plist_temp" \
        >/dev/null 2>&1; then
    print -u2 -- "error=invalid_rendered_sleep_guard_plist"
    exit 1
fi

sleep_guard_update_required=true
if [[ -f "$sleep_guard_target" && -f "$sleep_guard_plist" ]] \
    && cmp -s "$sleep_guard_source" "$sleep_guard_target" \
    && cmp -s "$sleep_guard_plist_temp" "$sleep_guard_plist" \
    && sleep_guard_service_is_running; then
    sleep_guard_update_required=false
fi

if [[ "$sleep_guard_update_required" == true ]]; then
    run_as_admin /bin/zsh -c '
set -eu
service_target=$1
helper_source=$2
helper_target=$3
plist_source=$4
plist_target=$5

if /bin/launchctl print "$service_target" >/dev/null 2>&1; then
    /bin/launchctl bootout "$service_target"
    for _ in {1..50}; do
        ! /bin/launchctl print "$service_target" >/dev/null 2>&1 && break
        /bin/sleep 0.1
    done
fi
if /bin/launchctl print "$service_target" >/dev/null 2>&1; then
    print -u2 -- "error=installed_sleep_guard_still_loaded"
    exit 1
fi

/usr/bin/install -o root -g wheel -m 755 "$helper_source" "$helper_target"
/usr/bin/install -o root -g wheel -m 644 "$plist_source" "$plist_target"
/bin/launchctl bootstrap system "$plist_target"
/bin/launchctl kickstart "$service_target"
' codex-sleep-guard-install \
    "$sleep_guard_service_target" \
    "$sleep_guard_source" \
    "$sleep_guard_target" \
    "$sleep_guard_plist_temp" \
    "$sleep_guard_plist"
fi

if [[ $(stat -f '%Su:%Sg:%OLp' "$sleep_guard_target") != root:wheel:755 \
    || $(stat -f '%Su:%Sg:%OLp' "$sleep_guard_plist") != root:wheel:644 \
    || $(code_identifier "$sleep_guard_target") != "$sleep_guard_label" ]]; then
    print -u2 -- "error=installed_sleep_guard_identity_mismatch"
    exit 1
fi

for _ in {1..50}; do
    sleep_guard_service_is_running && break
    sleep 0.1
done

if ! sleep_guard_service_is_running; then
    print -u2 -- "error=installed_sleep_guard_not_running"
    exit 1
fi

mkdir -p "$HOME/Applications" "$agent_dir" "$log_dir"

if launchctl print "$service_target" >/dev/null 2>&1; then
    launchctl bootout "$service_target"
    for _ in {1..50}; do
        ! launchctl print "$service_target" >/dev/null 2>&1 && ! target_is_running && break
        sleep 0.1
    done
fi

if launchctl print "$service_target" >/dev/null 2>&1; then
    print -u2 -- "error=installed_launch_agent_still_loaded"
    exit 1
fi

if target_is_running; then
    print -u2 -- "error=installed_app_still_running action=quit_menu_app_and_retry"
    exit 1
fi

rm -rf "$target_app"
ditto "$source_app" "$target_app"

plutil -lint "$target_app/Contents/Info.plist"
if ! installed_bundle_id=$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist" 2>/dev/null) \
    || ! installed_executable=$(plutil -extract CFBundleExecutable raw "$target_app/Contents/Info.plist" 2>/dev/null); then
    print -u2 -- "error=invalid_installed_bundle"
    exit 1
fi
if [[ "$installed_bundle_id" != "$label" || "$installed_executable" != "CodexAccountMenuBar" \
    || ! -x "$target_binary" ]]; then
    print -u2 -- "error=installed_bundle_identity_mismatch"
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$target_app"

cat > "$agent_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$target_binary</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$log_dir/CodexAccountSwitcher.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/CodexAccountSwitcher.err.log</string>
</dict>
</plist>
PLIST

plutil -lint "$agent_path"

launchctl bootstrap "$gui_target" "$agent_path"
launchctl kickstart "$service_target"

for _ in {1..50}; do
    service_is_running && break
    sleep 0.1
done

if ! service_is_running; then
    print -u2 -- "error=installed_app_not_running"
    exit 1
fi

sleep 1
if ! service_is_running; then
    print -u2 -- "error=installed_app_not_stable"
    exit 1
fi

print -- "installed=$target_app"
print -- "launch_agent=$agent_path"
print -- "sleep_guard=$sleep_guard_target"

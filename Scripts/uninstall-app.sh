#!/bin/zsh
set -eu

target_app="$HOME/Applications/CodexAccountSwitcher.app"
target_binary="$target_app/Contents/MacOS/CodexAccountMenuBar"
agent_path="$HOME/Library/LaunchAgents/local.codex.account-switcher.plist"
sleep_guard_target="/Library/PrivilegedHelperTools/local.codex.account-switcher.sleep-guard"
sleep_guard_plist="/Library/LaunchDaemons/local.codex.account-switcher.sleep-guard.plist"
label=local.codex.account-switcher
sleep_guard_label=local.codex.account-switcher.sleep-guard
gui_target="gui/$(id -u)"
service_target="$gui_target/$label"
sleep_guard_service_target="system/$sleep_guard_label"
install_uid=$(id -u)
expected_program_line=$'\tprogram = '"$target_binary"
expected_running_line=$'\tstate = running'
expected_sleep_guard_program_line=$'\tprogram = '"$sleep_guard_target"

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
    print -u2 -- "error=unsafe_uninstall_target reason=symlink"
    exit 1
fi

if [[ -e "$target_app" ]]; then
    if ! existing_bundle_id=$(plutil -extract CFBundleIdentifier raw "$target_app/Contents/Info.plist" 2>/dev/null); then
        print -u2 -- "error=unsafe_uninstall_target reason=unknown_bundle"
        exit 1
    fi
    if [[ "$existing_bundle_id" != "$label" ]]; then
        print -u2 -- "error=unsafe_uninstall_target reason=bundle_id_mismatch"
        exit 1
    fi
fi

if [[ -e "$agent_path" ]]; then
    if ! existing_agent_label=$(plutil -extract Label raw "$agent_path" 2>/dev/null) \
        || ! existing_agent_program=$(plutil -extract ProgramArguments.0 raw "$agent_path" 2>/dev/null); then
        print -u2 -- "error=unsafe_uninstall_target reason=unknown_launch_agent"
        exit 1
    fi
    if [[ "$existing_agent_label" != "$label" || "$existing_agent_program" != "$target_binary" ]]; then
        print -u2 -- "error=unsafe_uninstall_target reason=launch_agent_mismatch"
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

if [[ -e "$sleep_guard_target" || -e "$sleep_guard_plist" ]] \
    || launchctl print "$sleep_guard_service_target" >/dev/null 2>&1; then
    run_as_admin /bin/zsh -c '
set -eu
service_target=$1
plist_target=$2
helper_target=$3

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

/bin/rm -f "$plist_target" "$helper_target"
' codex-sleep-guard-uninstall \
        "$sleep_guard_service_target" \
        "$sleep_guard_plist" \
        "$sleep_guard_target"
fi

if launchctl print "$sleep_guard_service_target" >/dev/null 2>&1; then
    print -u2 -- "error=installed_sleep_guard_still_loaded"
    exit 1
fi
if [[ -e "$sleep_guard_target" || -e "$sleep_guard_plist" ]]; then
    print -u2 -- "error=installed_sleep_guard_still_present"
    exit 1
fi

if service_state=$(launchctl print "$service_target" 2>/dev/null); then
    if [[ ! -e "$agent_path" ]]; then
        print -u2 -- "error=unsafe_uninstall_target reason=unmanaged_launch_agent"
        exit 1
    fi
    if ! grep -Fqx -- "$expected_program_line" <<< "$service_state"; then
        print -u2 -- "error=unsafe_uninstall_target reason=loaded_program_mismatch"
        exit 1
    fi
    if grep -Fqx -- "$expected_running_line" <<< "$service_state" && ! service_is_running; then
        print -u2 -- "error=unsafe_uninstall_target reason=loaded_process_mismatch"
        exit 1
    fi
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

rm -f "$agent_path"
rm -rf "$target_app"

print -- "uninstalled=$target_app"
print -- "removed_sleep_guard=$sleep_guard_target"
print -- "preserved=application_support,keychain,logs,sleep_setting"

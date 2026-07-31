#!/bin/zsh
set -eu

project_dir=${0:A:h:h}
source_app="$project_dir/.build/CodexAccountSwitcher.app"
target_app="$HOME/Applications/CodexAccountSwitcher.app"
target_binary="$target_app/Contents/MacOS/CodexAccountMenuBar"
agent_dir="$HOME/Library/LaunchAgents"
agent_path="$agent_dir/local.codex.account-switcher.plist"
log_dir="$HOME/Library/Logs"
label=local.codex.account-switcher
gui_target="gui/$(id -u)"
service_target="$gui_target/$label"
expected_program_line=$'\tprogram = '"$target_binary"
expected_running_line=$'\tstate = running'

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

if [[ -L "$target_app" || -L "$agent_path" ]]; then
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

"$project_dir/Scripts/build-app.sh"

mkdir -p "$HOME/Applications" "$agent_dir" "$log_dir"

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
codesign --verify --strict --verbose=2 "$target_app"

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

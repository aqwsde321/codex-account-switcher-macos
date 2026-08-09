#!/bin/zsh
set -eu

project_dir=${0:A:h:h}
app_path="$project_dir/.build/CodexAccountSwitcher.app"
binary_name=CodexAccountMenuBar

"$project_dir/Scripts/dev.sh" build -c release --product "$binary_name"
binary_dir=$("$project_dir/Scripts/dev.sh" build -c release --show-bin-path)
binary_path="$binary_dir/$binary_name"

if [[ ! -x "$binary_path" ]]; then
    print -u2 -- "error=release_binary_not_found"
    exit 1
fi

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
mkdir -p "$app_path/Contents/Resources"
install -m 644 "$project_dir/Scripts/CodexAccountSwitcher-Info.plist" "$app_path/Contents/Info.plist"
install -m 755 "$binary_path" "$app_path/Contents/MacOS/$binary_name"
install -m 644 "$project_dir/Resources/CodexAccountSwitcher.png" "$app_path/Contents/Resources/CodexAccountSwitcher.png"

plutil -lint "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
codesign --verify --strict --verbose=2 "$app_path"

print -- "$app_path"

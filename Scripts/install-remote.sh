#!/bin/zsh
set -eu

readonly release_ref=v0.2.0
readonly archive_url=${CODEX_ACCOUNT_SWITCHER_TEST_ARCHIVE_URL:-https://github.com/aqwsde321/codex-account-switcher-macos/archive/refs/tags/$release_ref.tar.gz}

case ${1:-} in
    "")
        action=install
        script_name=install-app.sh
        ;;
    --uninstall)
        action=uninstall
        script_name=uninstall-app.sh
        ;;
    -h|--help)
        print -- "usage: install-remote.sh [--uninstall]"
        exit 0
        ;;
    *)
        print -u2 -- "error=invalid_argument expected=--uninstall"
        exit 64
        ;;
esac

if (( $# > 1 )); then
    print -u2 -- "error=too_many_arguments"
    exit 64
fi

if [[ $(uname -s) != Darwin ]]; then
    print -u2 -- "error=unsupported_platform expected=macOS"
    exit 1
fi

for required_command in curl tar mktemp; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        print -u2 -- "error=missing_command command=$required_command"
        exit 1
    fi
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-account-switcher.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM
archive_path="$work_dir/source.tar.gz"
extract_dir="$work_dir/source"
mkdir -p "$extract_dir"

print -- "download=$archive_url"
curl -fsSL "$archive_url" -o "$archive_path"
tar -xzf "$archive_path" -C "$extract_dir"

source_dirs=("$extract_dir"/*(/N))
if (( ${#source_dirs[@]} != 1 )); then
    print -u2 -- "error=invalid_source_archive reason=expected_single_root"
    exit 1
fi

script_path="${source_dirs[1]}/Scripts/$script_name"
if [[ ! -f "$script_path" || -L "$script_path" || ! -x "$script_path" ]]; then
    print -u2 -- "error=invalid_source_archive reason=missing_$script_name"
    exit 1
fi

print -- "source_ref=$release_ref"
print -- "action=$action"
"$script_path"

#!/bin/zsh
set -eu

project_dir=${0:A:h:h}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-account-switcher-test.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM
fixture_dir="$work_dir/codex-account-switcher-macos-v0.2.0"
archive_path="$work_dir/source.tar.gz"
marker_path="$work_dir/action"
bootstrap_url="file://$project_dir/Scripts/install-remote.sh"
mkdir -p "$fixture_dir/Scripts"

cat > "$fixture_dir/Scripts/install-app.sh" <<'SCRIPT'
#!/bin/zsh
set -eu
print -r -- install > "$CODEX_ACCOUNT_SWITCHER_TEST_MARKER"
SCRIPT

cat > "$fixture_dir/Scripts/uninstall-app.sh" <<'SCRIPT'
#!/bin/zsh
set -eu
print -r -- uninstall > "$CODEX_ACCOUNT_SWITCHER_TEST_MARKER"
SCRIPT

chmod +x "$fixture_dir/Scripts/install-app.sh" "$fixture_dir/Scripts/uninstall-app.sh"
tar -czf "$archive_path" -C "$work_dir" "${fixture_dir:t}"

export CODEX_ACCOUNT_SWITCHER_TEST_ARCHIVE_URL="file://$archive_path"
export CODEX_ACCOUNT_SWITCHER_TEST_MARKER="$marker_path"

(set -o pipefail && curl -fsSL "$bootstrap_url" | /bin/zsh)
[[ $(<"$marker_path") == install ]]

(set -o pipefail && curl -fsSL "$bootstrap_url" | /bin/zsh -s -- --uninstall)
[[ $(<"$marker_path") == uninstall ]]

if (set -o pipefail && curl -fsSL "$bootstrap_url" | /bin/zsh -s -- --invalid) \
    >/dev/null 2>&1; then
    print -u2 -- "error=invalid_argument_was_accepted"
    exit 1
fi

print -- "ok=remote_installer"

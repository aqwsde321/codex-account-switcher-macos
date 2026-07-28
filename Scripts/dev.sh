#!/bin/zsh
set -eu

project_dir=${0:A:h:h}
build_dir="$project_dir/.build"
compatibility_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk

if [[ -n ${SWITCHER_SDKROOT:-} ]]; then
    sdk_path=$SWITCHER_SDKROOT
elif [[ -d "$compatibility_sdk" ]]; then
    sdk_path=$compatibility_sdk
else
    sdk_path=$(xcrun --sdk macosx --show-sdk-path) || {
        print -u2 -- "error=macosx_sdk_not_found"
        exit 1
    }
fi

if [[ ! -d "$sdk_path" ]]; then
    print -u2 -- "error=invalid_sdk_path"
    exit 1
fi

swift_path=$(xcrun --find swift) || {
    print -u2 -- "error=swift_toolchain_not_found"
    exit 1
}

if (( $# == 0 )); then
    print -u2 -- "usage: ./Scripts/dev.sh <build|test|run> [arguments...]"
    exit 64
fi

action=$1
shift
cd "$project_dir"

common=(
    --disable-sandbox
    --cache-path "$build_dir/swiftpm-cache"
    --config-path "$build_dir/swiftpm-config"
    --security-path "$build_dir/swiftpm-security"
    --scratch-path "$build_dir/scratch"
    --manifest-cache none
)

export SDKROOT="$sdk_path"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-module-cache"

case "$action" in
    build)
        exec "$swift_path" build "${common[@]}" "$@"
        ;;
    test)
        exec "$swift_path" run "${common[@]}" codex-account-core-tests "$@"
        ;;
    run)
        exec "$swift_path" run "${common[@]}" codex-account-spike "$@"
        ;;
    *)
        print -u2 -- "error=invalid_action"
        exit 64
        ;;
esac

#!/bin/sh
set -eu

# Keep the package/cache location stable even when invoked from another folder.
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

build_system=${MEETGIST_BUILD_SYSTEM:-auto}
if [ "$build_system" = auto ]; then
    build_system=
    developer_dir=$(xcode-select -p 2>/dev/null || true)
    if [ "${developer_dir##*/}" = CommandLineTools ]; then
        case "$(swift --version 2>/dev/null)" in
            *"Swift version 6.4 "*|*"Swift version 6.4."*)
                # Swift 6.4's swiftbuild backend adds invalid Xcode-style CLT
                # search paths and rebuilds unchanged release targets here.
                # Temporary workaround: https://github.com/swiftlang/swift-package-manager/issues/10557
                # Keep the native-backend deprecation warning visible.
                build_system=native
                ;;
        esac
    fi
fi

case "$build_system" in
    "") exec swift build -c release "$@" ;;
    native|swiftbuild) exec swift build -c release --build-system "$build_system" "$@" ;;
    *)
        echo "MEETGIST_BUILD_SYSTEM must be auto, native, or swiftbuild." >&2
        exit 2
        ;;
esac

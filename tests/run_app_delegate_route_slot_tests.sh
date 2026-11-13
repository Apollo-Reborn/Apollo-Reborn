#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-route-slot.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

xcrun clang \
    -fobjc-arc \
    -fblocks \
    -Wall \
    -Wextra \
    -Werror \
    -fsanitize=address,undefined \
    -g \
    -O1 \
    -I"$test_root/src" \
    "$test_root/tests/app_delegate_route_slot_tests.m" \
    -framework Foundation \
    -o "$build_dir/route-slot-tests"

"$build_dir/route-slot-tests"

# The router must keep resolving the slot through the tested helper. An exact
# class check turns every tweak link off on Firebase-era Apollo builds (#1529).
source="$test_root/src/ApolloCommon.m"
if ! grep -Fq 'ApolloPointerIvarSlot(appDelegate, "_TtC6Apollo11AppDelegate", "tabBarController",' "$source"; then
    echo "ApolloRouteURLThroughAppInScene no longer uses ApolloPointerIvarSlot" >&2
    exit 1
fi
if grep -Fq 'isMemberOfClass:objc_getClass("_TtC6Apollo11AppDelegate")' "$source"; then
    echo "ApolloCommon.m checks the app delegate's exact class again (#1529)" >&2
    exit 1
fi

echo "app_delegate_route_slot_source_check passed"

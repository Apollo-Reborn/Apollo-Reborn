#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-share-link-mode.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM

common_flags="-fobjc-arc -Wall -Wextra -Werror -fsanitize=address,undefined"
# Compile the production helper as Objective-C and its consumer as Objective-C++.
# The separate objects make this a real linkage check for the extern-C boundary
# used by the Logos-generated .mm files.
# shellcheck disable=SC2086
xcrun --sdk macosx clang $common_flags -I"$repo/src" -c "$repo/src/ApolloShareAsImageLinkMode.m" -o "$build/mode.o"
# shellcheck disable=SC2086
xcrun --sdk macosx clang $common_flags -I"$repo/src" -c "$repo/tests/share_as_image_link_mode_tests.mm" -o "$build/tests.o"

nm -g "$build/mode.o" | grep -q ' T _ApolloShareLinkModeRead$'
nm -g "$build/mode.o" | grep -q ' T _ApolloShareLinkURLForMode$'
nm -u "$build/tests.o" | grep -q '^_ApolloShareLinkModeRead$'
nm -u "$build/tests.o" | grep -q '^_ApolloShareLinkURLForMode$'

# shellcheck disable=SC2086
xcrun --sdk macosx clang++ $common_flags -framework Foundation "$build/tests.o" "$build/mode.o" -o "$build/tests"
"$build/tests"

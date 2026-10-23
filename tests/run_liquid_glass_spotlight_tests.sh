#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-lg-spotlight-tests.XXXXXX")
test_binary="$build_dir/liquid_glass_spotlight_tests"
generated="$build_dir/LiquidGlassIconPreviews.gen.h"
trap 'rm -f -- "$test_binary" "$generated"; rmdir -- "$build_dir"' EXIT HUP INT TERM

# icons.json is the source of truth for the "seasons" lists; the checked-in
# header must match it (run `make lg-previews` after editing icons.json).
python3 "$repo_root/liquid-glass/scripts/generate_previews_header.py" "$generated" >/dev/null
if ! cmp -s "$generated" "$repo_root/liquid-glass/generated/LiquidGlassIconPreviews.gen.h"; then
    echo "liquid-glass/generated/LiquidGlassIconPreviews.gen.h is stale; run make lg-previews" >&2
    exit 1
fi

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -Wno-unused-const-variable \
    -framework Foundation -I "$repo_root/src" -I "$repo_root/liquid-glass/generated" \
    "$repo_root/tests/liquid_glass_spotlight_tests.m" \
    "$repo_root/src/ApolloLiquidGlassSpotlight.m" \
    -o "$test_binary"

"$test_binary" "$@"

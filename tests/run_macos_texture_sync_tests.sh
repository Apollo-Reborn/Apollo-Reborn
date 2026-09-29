#!/bin/sh
set -eu

test_repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_logos=${LOGOS:-${THEOS:-$HOME/theos}/bin/logos.pl}
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-macos-texture-sync.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

if [ ! -f "$test_logos" ]; then
    printf 'Logos not found at %s; set THEOS or LOGOS.\n' "$test_logos" >&2
    exit 1
fi

python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "src/ApolloCommentVoteFlicker.xm").read_text()
start_marker = "// MARK: - macOS Texture focus redraw\n"
end_marker = "// MARK: - end macOS Texture focus redraw\n"
if source.count(start_marker) != 1 or source.count(end_marker) != 1:
    raise SystemExit("cannot uniquely locate production Mac Texture fix")
start = source.index(start_marker) + len(start_marker)
end = source.index(end_marker, start)
production = source[start:end]
fixture = (root / "tests/macos_texture_sync_tests.m").read_text()
marker = "// PRODUCTION_MAC_TEXTURE_SYNC"
if fixture.count(marker) != 1:
    raise SystemExit("test fixture production marker is missing or duplicated")
(output / "MacTextureSync.xm").write_text(fixture.replace(marker, production))
(output / "substrate.h").write_text(
    "#import <objc/runtime.h>\n"
    "void MSHookMessageEx(Class, SEL, IMP, IMP *);\n"
)
PY

for test_generator in internal MobileSubstrate; do
    test_substrate=0
    if [ "$test_generator" = MobileSubstrate ]; then test_substrate=1; fi
    perl "$test_logos" -c "generator=$test_generator" \
        "$test_build_dir/MacTextureSync.xm" > "$test_build_dir/MacTextureSync.mm"
    xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
        -DAPOLLO_VF_TEST_SUBSTRATE="$test_substrate" -framework Foundation -framework CoreGraphics \
        -I "$test_build_dir" "$test_build_dir/MacTextureSync.mm" \
        -o "$test_build_dir/macos_texture_sync_tests"
    for test_mode in ios native catalyst; do
        printf '%s generator, %s path\n' "$test_generator" "$test_mode"
        "$test_build_dir/macos_texture_sync_tests" "$test_mode"
    done
done

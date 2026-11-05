#!/bin/sh
set -eu

lookup_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lookup_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-native-search-vc-lookup.XXXXXX")
trap 'rm -rf -- "$lookup_build"' EXIT HUP INT TERM

# Compile the production controller lookup itself. The fixture runs it from a
# screen's -dealloc and then forms a weak reference to the result, which aborts
# in the runtime if the lookup hands back a screen that is being torn down.
python3 - "$lookup_root" "$lookup_build" <<'PY'
from pathlib import Path
import sys

root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloSearchNativeBar.xm').read_text()
start = source.index('// MARK: - Feed controller lookup')
end = source.index('// MARK: - End feed controller lookup', start)
helper = source[start:end]
fixture = (root / 'tests/native_search_vc_lookup_tests.m').read_text()
(build / 'native_search_vc_lookup_tests.m').write_text(fixture.replace('// PRODUCTION_SOURCE', helper))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$lookup_build/native_search_vc_lookup_tests.m" \
    -o "$lookup_build/native_search_vc_lookup_tests"
"$lookup_build/native_search_vc_lookup_tests"

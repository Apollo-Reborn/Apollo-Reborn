#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_logos=${LOGOS:-${THEOS:-$HOME/theos}/bin/logos.pl}
if [ ! -f "$test_logos" ]; then
    printf 'Logos not found at %s; set THEOS or LOGOS.\n' "$test_logos" >&2
    exit 1
fi
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-profile-pagination.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Exercise the shipping hooks and completion guard with Foundation-only UIKit,
# RDK and ASBatchContext doubles. No copied implementation of the guard.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloProfilePagination.xm').read_text()
test = (root / 'tests/profile_pagination_tests.m').read_text()
source = source[source.index('typedef void (^ApolloProfileOverviewCompletion)'):]
(output / 'ProfilePagination.xm').write_text(test.replace('// INCLUDE_PRODUCTION_GUARD', source))
PY

perl "$test_logos" -c generator=internal "$test_build_dir/ProfilePagination.xm" > "$test_build_dir/ProfilePagination.mm"
xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation "$test_build_dir/ProfilePagination.mm" -o "$test_build_dir/profile_pagination_tests"
"$test_build_dir/profile_pagination_tests"

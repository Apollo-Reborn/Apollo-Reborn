#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-update-checker-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Compile the shipping coordinator with host doubles only at its UIKit, clock,
# timer and network boundaries. Its scheduling/presentation logic is unchanged.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, out = map(Path, sys.argv[1:])
source = (root / 'src/ApolloUpdateChecker.m').read_text()
source = '\n'.join(line for line in source.splitlines() if not line.startswith('#import '))
fixture = (root / 'tests/update_checker_tests.m').read_text()
marker = '// INSERT_PRODUCTION_CHECKER'
assert fixture.count(marker) == 1, 'checker fixture insertion marker missing or duplicated'
(out / 'tests.m').write_text(fixture.replace(marker, source))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -Wno-unused-function -Wno-unused-parameter -Wno-unused-variable -Wno-nullability-completeness \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloUpdateManifest.m" \
    "$test_repo_root/src/ApolloUpdateManifestCache.m" \
    "$test_build_dir/tests.m" -o "$test_build_dir/tests"

# Each scenario starts a fresh process, matching the checker's per-launch state.
for scenario in cadence active-timer failure-backoff manual-share manual-joins-auto manual-inactive prompt-deferred setup-deferred inactive opt-out pending-cancel skip cached-relaunch later later-relaunch later-newer later-offline; do
    "$test_build_dir/tests" "$scenario"
done

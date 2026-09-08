#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
pane_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-pane-tests.XXXXXX")
trap 'rm -rf "$pane_test_dir"' EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror tests/ipad/geometry-policy.c -o "$pane_test_dir/geometry"
"$pane_test_dir/geometry"
xcrun clang -fobjc-arc -framework Foundation tests/ipad/transition-observer.m src/ipad/ApolloPaneTransitionObserver.m src/ipad/ApolloPaneDiagnostics.m -o "$pane_test_dir/transitions"
"$pane_test_dir/transitions"

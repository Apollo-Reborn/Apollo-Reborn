#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-executable-sdk.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

python3 - "$test_repo_root/src/ApolloCommon.m" "$test_build_dir/ExecutableSDKSelection.inc" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
begin = source.index('static const char *ApolloNativeExecutableImageName(void)')
end = source.index('// Both the selected Apollo variant', begin)
Path(sys.argv[2]).write_text(source[begin:end])
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    -I "$test_repo_root/src" -I "$test_build_dir" \
    "$test_repo_root/tests/executable_sdk_tests.m" -o "$test_build_dir/executable_sdk_tests"
"$test_build_dir/executable_sdk_tests"

#!/bin/sh
set -eu

# Exercise the production request coordinator and completion-context guard.
# The harness replaces only provider/NL implementations so it can deterministically
# hold preparation in flight and prove duplicate requests coalesce off main.
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-translation-request.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM

python3 - "$repo/src/ApolloTranslation.xm" "$build/TranslationRequest.inc" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")

def function(signature, after=0):
    start = source.index(signature, after)
    return source[start:source.index("\n}\n", start) + 3]

prepared = source.index("static void ApolloStartPreparedTranslation(NSString *cacheKey,")
pieces = [
    function("static NSString *ApolloNormalizeTextForCompare(NSString *text) {"),
    function("static void ApolloStartPreparedTranslation(NSString *cacheKey,"),
    function("static void ApolloRequestTranslation(NSString *cacheKey,", prepared),
    function("static BOOL ApolloTranslationContextMatches(NSString *expectedSource,"),
]
Path(sys.argv[2]).write_text("\n".join(pieces), encoding="utf-8")
PY

xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Werror \
    -Wno-unused-function -fsanitize=address,undefined -framework Foundation \
    -I"$build" -x objective-c++ "$repo/tests/translation_request_concurrency_tests.mm" \
    -o "$build/tests"
"$build/tests"

#!/bin/sh
set -eu

# Translation markers name the language the PROVIDER reported translating from,
# and stay off text the provider handed back unchanged (issue #1345): Google
# response parsing, reported-code normalization, the source-language store key,
# and the unchanged-text compare (src/ApolloTranslation.xm).
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-translation-source.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM

python3 - "$repo/src/ApolloTranslation.xm" "$build/TranslationSourceLanguage.inc" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding='utf-8')

def function(signature):
    # One whole top-level function: its signature through the first column-0 brace.
    start = source.index(signature)
    return source[start:source.index('\n}\n', start) + 3]

pieces = [function(signature) for signature in (
    'static NSString *ApolloNormalizeLanguageCode(NSString *identifier) {',
    'static NSString *ApolloNormalizeTextForCompare(NSString *text) {',
    'static NSString *ApolloStripInlineMediaTokens(NSString *text) {',
    'static BOOL ApolloTranslatedTextDiffersFromSource(NSString *sourceText, NSString *translatedText) {',
    'static NSString *ApolloTranslationSourceLanguageKey(NSString *sourceText) {',
    'static NSString *ApolloNormalizedReportedSourceLanguage(NSString *reported) {',
    'static NSString *ApolloExtractGoogleSourceLanguage(id jsonObject) {',
)]
Path(sys.argv[2]).write_text('\n'.join(pieces), encoding='utf-8')
PY

xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Werror -Wno-unused-function \
    -fsanitize=address,undefined -framework Foundation -I"$build" \
    -x objective-c++ "$repo/tests/translation_source_language_tests.mm" -o "$build/tests"
"$build/tests"

#!/bin/sh
set -eu

# Comment/post-body translation: rendered-text vs markdown-source matching and the
# markdown-aware translated body renderer (src/ApolloTranslation.xm).
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-translation-markdown.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM

python3 - "$repo/src/ApolloTranslation.xm" "$build/TranslationMarkdown.inc" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding='utf-8')
ranges = [
    # Body matchers and the markdown fold they compare through.
    ('static NSString *ApolloNormalizeTextForCompare(NSString *text) {',
     'static BOOL ApolloTextIsSubstantiveForOwnershipCleanup('),
    ('static NSRange ApolloRangeByTrimmingTrailingURLPunctuation(',
     '// Reddit comment bodies embed inline media'),
    # Link helpers, the plain (title) builder and the markdown body builder.
    ('static NSDictionary *ApolloAttributesWithoutLinkAttribute(',
     'static BOOL ApolloThreadTranslationModeEnabledForVisibleCommentsVC(void) __attribute__((unused));'),
]
pieces = []
for start, end in ranges:
    a = source.index(start)
    pieces.append(source[a:source.index(end, a)])
Path(sys.argv[2]).write_text('\n'.join(pieces), encoding='utf-8')
PY

xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Werror -Wno-unused-function \
    -fsanitize=address,undefined -framework Foundation -framework AppKit -I"$build" \
    -x objective-c++ "$repo/tests/translation_markdown_body_tests.mm" -o "$build/tests"
"$build/tests"

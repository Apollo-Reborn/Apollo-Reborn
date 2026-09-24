#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-listing-response.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
python3 - "$repo" "$build" <<'PYGEN'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
s = (root / 'src/ApolloWebJSON.m').read_text()
classification = s.split('#pragma mark - Path classification', 1)[1].split('// Whitelist a write', 1)[0]
guard = s.split('static BOOL ApolloWebJSONPathExpectsListingDictionary', 1)[1].split('#pragma mark - Invited-moderators', 1)[0]
guard = 'static BOOL ApolloWebJSONPathExpectsListingDictionary' + guard
hooks = (root / 'src/ApolloWebJSONIdentity.xm').read_text().split('// Validate at the request completion boundary', 1)[1].split('%hook RDKResponseSerializer', 1)[0]
hooks = hooks[hooks.index('%hook RDKClient'):]
test = (root / 'tests/listing_response_tests.m').read_text()
(output / 'ListingResponse.xm').write_text(test.replace('// PRODUCTION_HELPERS', classification + guard).replace('// PRODUCTION_HOOK', hooks + '\n%ctor { %init; }\n'))
PYGEN
perl "${THEOS:-$HOME/theos}/bin/logos.pl" -c generator=internal "$build/ListingResponse.xm" > "$build/ListingResponse.mm"
xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function \
    -fsanitize=address,undefined -framework Foundation "$build/ListingResponse.mm" -o "$build/tests"
"$build/tests"

#!/bin/sh
set -eu
review_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
review_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-review.XXXXXX")
trap 'rm -rf -- "$review_build"' EXIT HUP INT TERM
python3 - "$review_root" "$review_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloNavigationActions.xm').read_text()
helpers = 'static NSMutableDictionary<NSString *, NSNumber *> *sDuoRailTops;\n'
for signature in ['static NSString *ApolloActionsDuoPoseKey(', 'static CGFloat ApolloActionsDuoRememberedTop(', 'static void ApolloActionsDuoRememberTop(', 'static BOOL ApolloActionsDuoRailIsTransitioning(']:
    start = source.index(signature)
    helpers += source[start:source.index('\n}', start) + 2] + '\n'
fixture = (root / 'tests/duo_rail_review_tests.m').read_text()
(build / 'review.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_HELPERS', helpers))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined -framework Foundation "$review_build/review.m" -o "$review_build/review"
"$review_build/review"

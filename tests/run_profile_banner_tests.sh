#!/bin/bash
set -euo pipefail
banner_root=$(cd "$(dirname "$0")/.." && pwd)
banner_tmp=$(mktemp -d /tmp/apollo-banner-tests.XXXXXX)
trap 'rm -rf "$banner_tmp"' EXIT
python3 - "$banner_root" "$banner_tmp" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
s = (root / 'src/ApolloUserProfileCache.m').read_text()
a = s.index('- (void)downloadBannerImageForURL:')
b = s.index('- (void)clearAllCaches', a)
fixture = (root / 'tests/profile_banner_url_tests.m').read_text()
(out / 'tests.m').write_text(fixture.replace('// INSERT_PRODUCTION_DOWNLOAD_METHOD', s[a:b]))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -I "$banner_root/src" -framework Foundation "$banner_tmp/tests.m" -o "$banner_tmp/tests"
"$banner_tmp/tests"

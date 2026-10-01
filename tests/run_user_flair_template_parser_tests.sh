#!/bin/sh
set -eu

unset CDPATH
test_repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "/tmp/apollo-user-flair-parser.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "src/ApolloUserFlair.xm").read_text()
start = source.index("static NSArray<NSDictionary *> *ApolloUserFlairTemplateRecordsFromJSONData")
end = source.index("static NSArray *ApolloUserFlairPiecesFromTemplateRecord", start)
parser = source[start:end]
test = (root / "tests/user_flair_template_parser_tests.m").read_text()
(output / "user_flair_template_parser_tests.mm").write_text(
    test.replace("// PRODUCTION_PARSER", parser)
)

fetch_start = source.index("static id ApolloUserFlairFetchWebOptions")
fetch_end = source.index("static NSError *ApolloUserFlairWebAPIError", fetch_start)
fetch = source[fetch_start:fetch_end]
required = (
    "https://oauth.reddit.com/r/%@/api/user_flair_v2?raw_json=1",
    "ApolloWebJSONKeylessOAuthBearer(username)",
    "ApolloWebJSONProbeURL(selectorURL)",
    "ApolloUserFlairWebOptionsFromJSON",
)
for needle in required:
    if needle not in fetch:
        raise SystemExit(f"missing keyless flair migration invariant: {needle}")
for forbidden in ("/api/flairselector", "ApolloUserFlairWebOptionsFromHTML"):
    if forbidden in fetch:
        raise SystemExit(f"legacy flair option dependency remains: {forbidden}")
PY

xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -framework Foundation "$test_build_dir/user_flair_template_parser_tests.mm" \
    -o "$test_build_dir/user_flair_template_parser_tests"
"$test_build_dir/user_flair_template_parser_tests"

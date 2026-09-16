#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_logos=${LOGOS:-${THEOS:-$HOME/theos}/bin/logos.pl}
if [ ! -f "$test_logos" ]; then
    printf 'Logos not found at %s; set THEOS or LOGOS.\n' "$test_logos" >&2
    exit 1
fi
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-multireddit-expansion.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Execute the shipping scope helper AND the complete six UITableView hook
# bodies. Only the unrelated Following-map helpers and UIKit are doubled.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import re
import sys

root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloFollowingSection.xm').read_text()
group = source.split('%group ApolloFollowingTable', 1)[1].split('%end // group ApolloFollowingTable', 1)[0]
names = ('reloadData', 'beginUpdates', 'endUpdates', 'insertRowsAtIndexPaths',
         'deleteRowsAtIndexPaths', 'reloadRowsAtIndexPaths')
methods = []
for name in names:
    start = re.search(r'^- \(void\)' + name + r'(?=[: {])', group, re.M)
    if start is None:
        raise SystemExit(f'Missing production table hook: {name}')
    # Every method's closing brace is at column zero; nested blocks are indented.
    end = group.index('\n}', start.start()) + 2
    methods.append(group[start.start():end])
hooks = '%group ExpansionTableTests\n%hook UITableView\n' + '\n\n'.join(methods)
hooks += '\n%end\n%end\n%ctor { %init(ExpansionTableTests); }\n'
test = (root / 'tests/multireddit_expansion_tests.m').read_text()
(output / 'MultiredditExpansion.xm').write_text(test.replace('// INCLUDE_PRODUCTION_TABLE_HOOKS', hooks))
PY

perl "$test_logos" -c generator=internal "$test_build_dir/MultiredditExpansion.xm" > "$test_build_dir/MultiredditExpansion.mm"
xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    -I "$test_repo_root/src" "$test_build_dir/MultiredditExpansion.mm" \
    -o "$test_build_dir/multireddit_expansion_tests"
"$test_build_dir/multireddit_expansion_tests"

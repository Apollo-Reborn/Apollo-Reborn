#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-report-log-trim.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
python3 - "$test_root/src/settings/ApolloReportViewController.m" "$test_dir/ReportLogTrim.inc" <<'EXTRACT'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
start = s.index('static const NSUInteger kApolloReportMaxLogBytes')
end = s.index('// WKUserContentController retains message handlers', start)
Path(sys.argv[2]).write_text(s[start:end])
EXTRACT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -I "$test_dir" "$test_root/tests/report_log_trim_tests.m" -o "$test_dir/test"
"$test_dir/test"

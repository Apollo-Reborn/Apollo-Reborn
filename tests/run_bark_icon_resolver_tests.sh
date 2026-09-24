#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-bark-icon-tests.XXXXXX")
test_binary="$build_dir/bark_icon_resolver_tests"
trap 'rm -f -- "$test_binary"; rmdir -- "$build_dir"' EXIT HUP INT TERM

python3 "$repo_root/scripts/generate-bark-icon-names.py" \
    "$repo_root/assets/bark-icons" \
    "$repo_root/src/generated/ApolloBarkIconNames.gen.h" \
    --check

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$repo_root/src" \
    "$repo_root/tests/bark_icon_resolver_tests.m" \
    "$repo_root/src/ApolloBarkIconResolver.m" \
    -o "$test_binary"

# Exercise every current picker ID that survives the existing LG-classics
# normalization but has no repository-hosted Bark PNG. This keeps the issue
# fix covering the whole selectable set as icons are added or removed.
missing_icons=$(python3 - "$repo_root/liquid-glass/icons.json" "$repo_root/assets/bark-icons" <<'PY'
import json
import pathlib
import sys

catalog = json.loads(pathlib.Path(sys.argv[1]).read_text())
hosted = {path.stem for path in pathlib.Path(sys.argv[2]).glob("*.png")}
missing = []
for entry in catalog.get("icons", []):
    icon_id = entry.get("id", "")
    normalized = icon_id[3:] if icon_id.startswith("LG-") and icon_id[3:] in hosted else icon_id
    if normalized and normalized not in hosted:
        missing.append(normalized)
if not missing:
    raise SystemExit("expected at least one selectable icon without a hosted Bark PNG")
print(" ".join(sorted(set(missing))))
PY
)

# Icon IDs are catalog identifiers and cannot contain shell whitespace.
# shellcheck disable=SC2086
"$test_binary" $missing_icons

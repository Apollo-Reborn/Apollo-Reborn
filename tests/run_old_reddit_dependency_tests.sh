#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

python3 - "$repo" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

# These files used to make operational requests or route sign-in to Old Reddit.
# Inbound URL compatibility lives elsewhere and is intentionally not scanned.
runtime_files = [
    "src/ApolloWebJSON.m",
    "src/ApolloUserFlair.xm",
    "src/ApolloBadgeBookScraper.m",
    "src/ApolloWebAuthViewController.m",
    "src/ApolloWebSessionLoginViewController.m",
    "userscript/apollo-oauth-helper.user.js",
]
for relative in runtime_files:
    text = (root / relative).read_text()
    if "old.reddit.com" in text.lower():
        raise SystemExit(f"operational Old Reddit dependency remains in {relative}")

flair = (root / "src/ApolloUserFlair.xm").read_text()
if "ApolloUserFlairWebOptionsFromHTML" in flair or 'ApolloUserFlairWebRequest(@"/api/flairselector"' in flair:
    raise SystemExit("keyless flair choices still parse the legacy HTML selector")
if "api/user_flair_v2?raw_json=1" not in flair:
    raise SystemExit("keyless flair choices are not using the modern JSON endpoint")

state = (root / "src/ApolloState.h").read_text()
settings = (root / "src/settings/CustomAPIViewController.m").read_text()
startup = (root / "src/Tweak.xm").read_text()
if "ShareLinkHostRetiredOldReddit = 1" not in state:
    raise SystemExit("retired share-host value must remain reserved for backup compatibility")
if "ShareLinkHostOldReddit" in state + settings:
    raise SystemExit("Old Reddit is still selectable as an outbound share host")
if "sShareLinkHost == ShareLinkHostRetiredOldReddit" not in startup:
    raise SystemExit("stored Old Reddit share-host values are not migrated")

readme = (root / "README.md").read_text().lower()
if "old.reddit.com/prefs" in readme:
    raise SystemExit("README still requires the legacy preferences page")

# Keep inbound compatibility. Existing old links must still open in Apollo even
# though Apollo no longer generates or depends on that host.
link_tests = (root / "safari-extension/link-utils.test.js").read_text().lower()
if "old.reddit.com" not in link_tests:
    raise SystemExit("inbound Old Reddit URL compatibility lost its regression fixture")

# The announcement is context only: Apollo has no RSS feature to migrate.
source_roots = [root / "src", root / "widgets"]
for source_root in source_roots:
    for path in source_root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".m", ".mm", ".h", ".xm", ".swift", ".js"}:
            continue
        text = path.read_text(errors="ignore").lower()
        if ".rss" in text or "application/rss" in text or "application/atom+xml" in text:
            raise SystemExit(f"unexpected RSS dependency in {path.relative_to(root)}")

print("Old Reddit dependency policy checks passed")
PY

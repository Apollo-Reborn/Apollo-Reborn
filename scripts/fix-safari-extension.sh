#!/bin/bash
set -euo pipefail

# Repairs the bundled "Open in Apollo" Safari Web Extension (Apollofari.appex)
# inside an IPA, in place.
#
# The stock extension's "Automatic" mode redirected through
# https://openinapollo.com, whose auto-open relies on an iOS Smart App Banner
# bound to the App Store Apollo (app id 979274575). A sideloaded build is not
# that app, so the banner never fires and users are stranded on the interstitial.
# We overlay the fixed web assets from safari-extension/ (direct apollo://
# redirect, no dangling background.js, MutationObserver, /s/ share-link support).
#
# The tweak dylib can't do this at runtime — the extension runs in Safari's
# separate process — so the repair happens at IPA-package time, where the user's
# signer (AltStore/SideStore/Feather/TrollStore) re-seals the modified appex.
#
# No-op (exit 0) when the IPA has no Apollofari.appex (the no-extensions variants).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSET_DIR="${REPO_DIR}/safari-extension"

usage() {
    echo "Usage: $0 <path-to-ipa>"
    echo ""
    echo "Overlays safari-extension/{content.js,manifest.json} onto Apollofari.appex"
    echo "and removes the appex code signature so the user's signer re-seals it."
    echo "Exits 0 without changes if the IPA contains no Apollofari.appex."
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
    exit 1
fi

IPA_PATH="$1"

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found: $IPA_PATH"
    exit 1
fi

for asset in content.js manifest.json; do
    if [[ ! -f "$ASSET_DIR/$asset" ]]; then
        echo "Error: missing overlay asset: $ASSET_DIR/$asset"
        exit 1
    fi
done

# Resolve to absolute so the re-zip targets the same file regardless of cwd.
case "$IPA_PATH" in
    /*) : ;;
    *) IPA_PATH="$PWD/$IPA_PATH" ;;
esac

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

if ! (cd "$work" && unzip -q "$IPA_PATH"); then
    echo "Error: could not unzip IPA: $IPA_PATH"
    exit 1
fi

appex="$(find "$work/Payload" -type d -name "Apollofari.appex" -print -quit 2>/dev/null || true)"
if [[ -z "$appex" || ! -d "$appex" ]]; then
    echo "No Apollofari.appex in $(basename "$IPA_PATH") — skipping Safari extension fix."
    exit 0
fi

echo "Repairing Safari extension in $(basename "$IPA_PATH")..."
cp "$ASSET_DIR/content.js" "$appex/content.js"
cp "$ASSET_DIR/manifest.json" "$appex/manifest.json"

# The appex's prior signature covers the now-modified web assets — remove it so
# the user's signer re-seals cleanly (mirrors the CydiaSubstrate/main-app
# handling in build-ipa.sh and build_release_variants.sh).
rm -rf "$appex/_CodeSignature"

rm -f "$IPA_PATH"
if ! (cd "$work" && zip -qry "$IPA_PATH" Payload); then
    echo "Error: could not re-zip IPA after Safari extension fix."
    exit 1
fi

echo "Safari extension repaired: content.js + manifest.json overlaid, _CodeSignature removed."

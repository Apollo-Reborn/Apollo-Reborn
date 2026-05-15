#!/bin/bash
set -euo pipefail

IPA_PATH=""
DEB_PATH=""
OUTPUT_IPA="Apollo-Tweaked.ipa"

usage() {
    echo "Usage: $0 --ipa <Apollo.ipa> [--deb <packages/*.deb>] [-o <output.ipa>]"
    echo ""
    echo "Options:"
    echo "  --ipa <file>      Path to base Apollo IPA (required)"
    echo "  --deb <file>      Path to tweak .deb (default: newest in packages/)"
    echo "  -o, --output      Output IPA filename (default: Apollo-Tweaked.ipa)"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --ipa ./Apollo.ipa"
    echo "  $0 --ipa ./Apollo.ipa --deb ./packages/ca.jeffrey.apollo-improvedcustomapi_*.deb -o ./packages/Apollo-Tweaked.ipa"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa)
            IPA_PATH="$2"
            shift 2
            ;;
        --deb)
            DEB_PATH="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_IPA="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$IPA_PATH" ]]; then
    echo "Error: --ipa is required"
    usage
    exit 1
fi

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found: $IPA_PATH"
    exit 1
fi

if [[ -z "$DEB_PATH" ]]; then
    latest_deb=$(ls -1t packages/*.deb 2>/dev/null | head -1 || true)
    if [[ -z "$latest_deb" ]]; then
        echo "Error: No .deb found in packages/. Run 'make package' first or pass --deb."
        exit 1
    fi
    DEB_PATH="$latest_deb"
fi

if [[ ! -f "$DEB_PATH" ]]; then
    echo "Error: .deb not found: $DEB_PATH"
    exit 1
fi

echo "Base IPA : $IPA_PATH"
echo "Tweak DEB: $DEB_PATH"
echo "Output   : $OUTPUT_IPA"

# iOS 26 dyld no longer accepts the legacy `arm64e.old` mach-o subtype that
# ships in the CydiaSubstrate.framework azule bundles
# (apt.bingner.com/debs/1443.00/mobilesubstrate_0.9.7113, April 2021). Even
# though the framework is fat (armv6/armv7/arm64/arm64e) and the arm64 slice
# is fine, dyld picks the arm64e slice first on an arm64e device and aborts.
# Strip the arm64e slice in-place; dyld then falls through to arm64.
strip_arm64e_from_substrate_in_ipa() {
    local ipa="$1"
    local work
    work="$(mktemp -d)"

    if ! (cd "$work" && unzip -q "$ipa"); then
        echo "Warning: could not unzip IPA for slice fix; leaving as-is."
        rm -rf "$work"
        return 0
    fi

    local framework_bin="$work/Payload/Apollo.app/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
    if [[ ! -f "$framework_bin" ]]; then
        rm -rf "$work"
        return 0
    fi

    if ! lipo -info "$framework_bin" 2>/dev/null | grep -qw 'arm64e'; then
        rm -rf "$work"
        return 0
    fi

    echo "Stripping arm64e slice from CydiaSubstrate (iOS 26 dyld fix)..."
    if ! lipo -remove arm64e "$framework_bin" -output "$framework_bin.new" 2>&1; then
        echo "Warning: lipo -remove arm64e failed; IPA may crash on iOS 26."
        rm -rf "$work"
        return 0
    fi
    mv -f "$framework_bin.new" "$framework_bin"

    # The framework's prior code signature covers the now-modified binary —
    # remove it so the user's signer (Sideloadly/AltStore/cert) re-signs cleanly.
    rm -rf "$(dirname "$framework_bin")/_CodeSignature"

    rm -f "$ipa"
    if ! (cd "$work" && zip -qry "$ipa" Payload); then
        echo "Error: could not re-zip IPA after slice fix."
        rm -rf "$work"
        return 1
    fi

    rm -rf "$work"
}

if command -v azule >/dev/null 2>&1; then
    echo "Using azule for injection..."

    # azule changes its working directory during injection, so relative paths
    # passed to -f / -i fall through to azule_apt's remote-repo lookup and fail
    # with "Couldn't find <basename>". Resolve to absolute paths up front.
    abs_ipa="$(cd "$(dirname "$IPA_PATH")" && pwd)/$(basename "$IPA_PATH")"
    abs_deb="$(cd "$(dirname "$DEB_PATH")" && pwd)/$(basename "$DEB_PATH")"

    # azule -o expects a directory, not a filename, and writes
    # "<ipa-stem>+<deb-stem>.ipa" into it. Use a scratch dir, then rename.
    out_dir="$(dirname "$OUTPUT_IPA")"
    mkdir -p "$out_dir"
    abs_out_dir="$(cd "$out_dir" && pwd)"
    scratch_dir="$(mktemp -d)"

    if azule -i "$abs_ipa" -f "$abs_deb" -o "$scratch_dir" -U; then
        generated="$(ls -1t "$scratch_dir"/*.ipa 2>/dev/null | head -1 || true)"
        if [[ -z "$generated" ]]; then
            echo "Error: azule reported success but produced no IPA."
            rm -rf "$scratch_dir"
            exit 1
        fi
        if ! strip_arm64e_from_substrate_in_ipa "$generated"; then
            rm -rf "$scratch_dir"
            exit 1
        fi
        mv -f "$generated" "$abs_out_dir/$(basename "$OUTPUT_IPA")"
        rm -rf "$scratch_dir"
        echo "Injected IPA created at: $OUTPUT_IPA"
        exit 0
    fi

    rm -rf "$scratch_dir"
    echo "Error: azule injection failed."
    exit 1
fi

if command -v cyan >/dev/null 2>&1; then
    echo "Using cyan for injection..."

    if cyan -i "$IPA_PATH" -f "$DEB_PATH" -o "$OUTPUT_IPA"; then
        echo "Injected IPA created at: $OUTPUT_IPA"
        exit 0
    fi

    echo "Error: cyan injection failed."
    exit 1
fi

echo "Error: Neither 'azule' nor 'cyan' is installed."
echo "Install one of them, then rerun this script."
exit 1

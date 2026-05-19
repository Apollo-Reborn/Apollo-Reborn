#!/bin/bash
set -euo pipefail

IPA_PATH=""
DEB_PATH=""
OUTPUT_IPA=""

usage() {
    echo "Usage: $0 --ipa <Apollo.ipa> --deb <packages/*.deb> -o <output.ipa>"
    echo ""
    echo "Local replacement injector for this repo's already-injected Apollo base IPA."
    echo "It replaces tweak dylibs from a Theos .deb inside Payload/*.app/Frameworks."
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

if [[ -z "$IPA_PATH" || -z "$DEB_PATH" || -z "$OUTPUT_IPA" ]]; then
    usage
    exit 1
fi

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "${1#./}" ;;
    esac
}

IPA_PATH="$(absolute_path "$IPA_PATH")"
DEB_PATH="$(absolute_path "$DEB_PATH")"
OUTPUT_IPA="$(absolute_path "$OUTPUT_IPA")"

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Error: IPA not found: $IPA_PATH"
    exit 1
fi

if [[ ! -f "$DEB_PATH" ]]; then
    echo "Error: .deb not found: $DEB_PATH"
    exit 1
fi
mkdir -p "$(dirname "$OUTPUT_IPA")"

for tool in ar install_name_tool tar unzip zip otool; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' is not installed."
        exit 1
    fi
done

tmpdir="$(mktemp -d /tmp/apollo-local-inject-XXXXXX)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$tmpdir/ipa" "$tmpdir/deb"
unzip -q "$IPA_PATH" -d "$tmpdir/ipa"

app_bundle="$(find "$tmpdir/ipa/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
if [[ -z "$app_bundle" ]]; then
    echo "Error: no .app bundle found in IPA."
    exit 1
fi

plist_path="$app_bundle/Info.plist"
executable_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist_path")"
executable_path="$app_bundle/$executable_name"
frameworks_dir="$app_bundle/Frameworks"
mkdir -p "$frameworks_dir"

(
    cd "$tmpdir/deb"
    ar -x "$DEB_PATH"
    data_archive="$(ls data.tar.* 2>/dev/null | head -1)"
    if [[ -z "$data_archive" ]]; then
        echo "Error: .deb did not contain data.tar.*"
        exit 1
    fi
    tar -xf "$data_archive"
)

dylib_dir="$tmpdir/deb/Library/MobileSubstrate/DynamicLibraries"
if [[ ! -d "$dylib_dir" ]]; then
    echo "Error: .deb did not contain MobileSubstrate DynamicLibraries."
    exit 1
fi

shopt -s nullglob
dylibs=("$dylib_dir"/*.dylib)
shopt -u nullglob
if [[ "${#dylibs[@]}" -eq 0 ]]; then
    echo "Error: .deb contained no dylibs to inject."
    exit 1
fi

missing_loads=()
for dylib in "${dylibs[@]}"; do
    name="$(basename "$dylib")"
    if ! otool -l "$executable_path" | /usr/bin/grep -F "$name" >/dev/null 2>&1 && [[ ! -f "$frameworks_dir/$name" ]]; then
        missing_loads+=("$name")
        continue
    fi
    cp "$dylib" "$frameworks_dir/$name"
    install_name_tool -id "@rpath/$name" "$frameworks_dir/$name" 2>/dev/null || true
    install_name_tool -change "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate" "@rpath/CydiaSubstrate.framework/CydiaSubstrate" "$frameworks_dir/$name" 2>/dev/null || true
    echo "Updated Frameworks/$name"
done

if [[ "${#missing_loads[@]}" -gt 0 ]]; then
    echo "Error: IPA is not already prepared to load: ${missing_loads[*]}"
    echo "Use azule/cyan once for a truly stock IPA, then this local injector can update it deterministically."
    exit 2
fi

rm -f "$OUTPUT_IPA"
(
    cd "$tmpdir/ipa"
    zip -qr "$OUTPUT_IPA" Payload
)

echo "Injected IPA created at: $OUTPUT_IPA"

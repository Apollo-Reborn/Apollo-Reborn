#!/bin/bash
# Build the Siri framework and embed it, with host-specific metadata, in Apollo.
# No application target, replacement executable, or extra extension is built.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IPA=""; APP=""; OUTPUT=""; SDK="iphoneos"

usage() {
    echo "Usage: $0 --ipa <Apollo.ipa> -o <new.ipa> [--sdk iphoneos]"
    echo "       $0 --app <prepared/Apollo.app> --sdk iphonesimulator"
    echo ""
    echo "--ipa writes a NEW unsigned iOS 27+ Apollo IPA; sign with your usual signer."
    echo "--app modifies a prepared Apollo bundle IN PLACE; the caller must re-sign it."
    echo "The framework is opt-in and is not included in normal release builds."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa|--app|-o|--output|--sdk)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            case "$1" in
                --ipa) IPA="$2";;
                --app) APP="$2";;
                -o|--output) OUTPUT="$2";;
                --sdk) SDK="$2";;
            esac
            shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2;;
    esac
done

die() { echo "Error: $*" >&2; exit 1; }
[[ "$SDK" == iphoneos || "$SDK" == iphonesimulator ]] || die "Unsupported SDK: $SDK"
[[ -n "$IPA" || -n "$APP" ]] || { usage >&2; exit 2; }
[[ -z "$IPA" || -z "$APP" ]] || die "Choose --ipa or --app, not both."
[[ -z "$APP" || -z "$OUTPUT" ]] || die "--output is only valid with --ipa."

WORK=""
cleanup() {
    # WORK is assigned only by mktemp below, never by caller input.
    if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

if [[ -n "$IPA" ]]; then
    [[ "$SDK" == iphoneos ]] || die "IPA packaging requires the device SDK."
    [[ -f "$IPA" ]] || die "IPA does not exist: $IPA"
    [[ -n "$OUTPUT" ]] || die "Specify a new output file with -o."
    [[ ! -e "$OUTPUT" ]] || die "Output already exists; choose a new filename: $OUTPUT"
    [[ "$OUTPUT" == /* ]] || OUTPUT="$PWD/$OUTPUT"
    [[ -d "$(dirname "$OUTPUT")" ]] || die "Output directory does not exist."
    WORK="$(mktemp -d -t apollo-siri)"
    unzip -q "$IPA" -d "$WORK"
    shopt -s nullglob
    APPS=("$WORK"/Payload/*.app)
    [[ ${#APPS[@]} == 1 ]] || die "Expected exactly one app in Payload."
    APP="${APPS[0]}"
fi

[[ -d "$APP" && -f "$APP/Info.plist" ]] || die "Not an app bundle: $APP"
APP="$(cd "$APP" && pwd)"
PB=/usr/libexec/PlistBuddy
EXECUTABLE="$($PB -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
[[ "$EXECUTABLE" == Apollo && -f "$APP/Apollo" ]] || die "Only Apollo's executable is supported."
BUNDLE_ID="$($PB -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
if [[ -d "$APP/Metadata.appintents" ]]; then
    [[ "$($PB -c 'Print :ApolloSiriProofVersion' "$APP/Info.plist" 2>/dev/null || true)" == 1 ]] \
        || die "Apollo already has App Intents metadata; refusing to overwrite another integration."
fi

BUILD_DIR="$REPO_ROOT/siri/build-$SDK"
PRODUCT="$BUILD_DIR/Build/Products/Release-$SDK/ApolloSiri.framework"
INTERMEDIATES="$BUILD_DIR/Build/Intermediates.noindex/ApolloSiri.build/Release-$SDK/ApolloSiri.build"
OBJECTS="$INTERMEDIATES/Objects-normal/arm64"
mkdir -p "$BUILD_DIR"
echo "Building ApolloSiri framework ($SDK)..."
xcodegen generate --spec "$REPO_ROOT/siri/project.yml" > "$BUILD_DIR/generate.log" 2>&1
if ! xcodebuild -project "$REPO_ROOT/siri/ApolloSiri.xcodeproj" -scheme ApolloSiri \
    -configuration Release -sdk "$SDK" -derivedDataPath "$BUILD_DIR" \
    ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build > "$BUILD_DIR/build.log" 2>&1; then
    tail -45 "$BUILD_DIR/build.log" >&2
    die "Framework build failed; see $BUILD_DIR/build.log"
fi

[[ -f "$PRODUCT/Metadata.appintents/extract.actionsdata" ]] || die "Framework metadata missing."
DESTINATION="$APP/Frameworks/ApolloSiri.framework"
mkdir -p "$APP/Frameworks"
if [[ -e "$DESTINATION" ]]; then
    [[ "$($PB -c 'Print :CFBundleIdentifier' "$DESTINATION/Info.plist" 2>/dev/null || true)" == app.apolloreborn.Siri ]] \
        || die "Refusing to replace an unrelated ApolloSiri.framework."
    rm -rf -- "$DESTINATION"
fi
ditto "$PRODUCT" "$DESTINATION"

# Re-injecting: host metadata is regenerated below for this bundle ID.
if [[ "$($PB -c 'Print :ApolloSiriProofVersion' "$APP/Info.plist" 2>/dev/null || true)" == 1 ]]; then
    rm -rf -- "$APP/Metadata.appintents"
fi

# Extract again for the REAL host bundle. Copying framework metadata verbatim
# does not establish host discovery. Keep the module name: the Swift types
# actually live in ApolloSiri. No App Shortcut phrases are defined.
SDK_ROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/{print $3}')"
TRIPLE=arm64-apple-ios27.0
[[ "$SDK" != iphonesimulator ]] || TRIPLE="$TRIPLE-simulator"
echo "Extracting Siri metadata for $BUNDLE_ID..."
xcrun appintentsmetadataprocessor \
    --toolchain-dir "$TOOLCHAIN" --module-name ApolloSiri --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_BUILD" --platform-family iOS --deployment-target 27.0 \
    --bundle-identifier "$BUNDLE_ID" --output "$APP" --target-triple "$TRIPLE" \
    --binary-file "$DESTINATION/ApolloSiri" \
    --source-file-list "$OBJECTS/ApolloSiri.SwiftFileList" \
    --swift-const-vals-list "$OBJECTS/ApolloSiri.SwiftConstValuesFileList" \
    --metadata-file-list "$INTERMEDIATES/ApolloSiri.DependencyMetadataFileList" \
    --static-metadata-file-list "$INTERMEDIATES/ApolloSiri.DependencyStaticMetadataFileList" \
    --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization

[[ -s "$APP/Metadata.appintents/extract.actionsdata" ]] || die "Host metadata missing."
# No appintentsnltrainingprocessor: there are no App Shortcut phrases. Fail
# packaging if any are accidentally introduced without that training step.
python3 - "$APP/Metadata.appintents/extract.actionsdata" "$DESTINATION/Metadata.appintents/extract.actionsdata" <<'PY'
import json
import sys
for path in sys.argv[1:]:
    with open(path) as source:
        metadata = json.load(source)
    if metadata.get("autoShortcuts"):
        raise SystemExit(f"Unexpected App Shortcut registrations in {path}")
    if not metadata.get("actions") or not metadata.get("entities"):
        raise SystemExit(f"App Intents or entity metadata missing from {path}")
print("Verified: no App Shortcut registrations; App Intents and entities retained.")
PY
python3 "$SCRIPT_DIR/macho_add_load_dylib.py" "$APP/Apollo" \
    '@executable_path/Frameworks/ApolloSiri.framework/ApolloSiri'

# The Siri IPA variant is iOS 27-only; the tweak's own iOS 14 floor is unchanged.
$PB -c 'Set :MinimumOSVersion 27.0' "$APP/Info.plist"
if ! $PB -c 'Set :ApolloSiriProofVersion 1' "$APP/Info.plist" 2>/dev/null; then
    $PB -c 'Add :ApolloSiriProofVersion integer 1' "$APP/Info.plist"
fi
for SIGNATURE in "$APP/_CodeSignature" "$DESTINATION/_CodeSignature"; do
    [[ ! -d "$SIGNATURE" ]] || rm -rf -- "$SIGNATURE"
done

if [[ -n "$OUTPUT" ]]; then
    (cd "$WORK" && zip -qry "$OUTPUT" Payload)
    echo "Created unsigned Apollo Siri IPA: $OUTPUT"
else
    echo "Embedded ApolloSiri.framework in $APP; re-sign before installing."
fi

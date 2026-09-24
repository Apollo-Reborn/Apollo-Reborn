#!/bin/bash
# Runs the real backup confirmation UI with a stub restore engine. No account data
# or real backup is read or written. Requires a booted iOS simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${SIM_DEVICE:-booted}"
BUNDLE=app.apolloreborn.backupdocumenttests
WORK="$(mktemp -d /tmp/apollo-backup-document-tests.XXXXXX)"
cleanup() {
    xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/Test.app"
python3 - "$WORK/Test.app/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(dict(
        CFBundleIdentifier='app.apolloreborn.backupdocumenttests', CFBundleExecutable='Test',
        CFBundleName='Backup Document Tests', CFBundlePackageType='APPL', CFBundleVersion='1',
        CFBundleShortVersionString='1', MinimumOSVersion='15.0', UIDeviceFamily=[1, 2],
        UILaunchScreen={}, UIApplicationSceneManifest={
            'UIApplicationSupportsMultipleScenes': False,
            'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'Test'}]}}), output)
PY
xcrun clang -target arm64-apple-ios15.0-simulator \
    -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" -fobjc-arc \
    -I "$ROOT/src" -framework UIKit -framework Foundation \
    "$ROOT/tests/backup_document_tests.m" "$ROOT/src/settings/ApolloBackupDocument.m" \
    -o "$WORK/Test.app/Test"
codesign -f -s - "$WORK/Test.app" >/dev/null
xcrun simctl install "$DEVICE" "$WORK/Test.app"
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)"
rm -f "$CONTAINER/Documents/results.json"
xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE"
for ((attempt=0; attempt<40; attempt++)); do
    [[ -f "$CONTAINER/Documents/results.json" ]] && break
    sleep 0.5
done
python3 - "$CONTAINER/Documents/results.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    checks = json.load(source)
for check in checks:
    print(('PASS' if check['passed'] else 'FAIL') + ': ' + check['check'])
assert len(checks) == 13 and all(check['passed'] for check in checks), 'Backup document UI checks failed'
PY

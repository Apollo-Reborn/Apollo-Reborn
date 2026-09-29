#!/bin/sh
# Host-side checks for restore's keychain-record filter in ApolloBackupRestore.m:
# pre-3.8 archives carry rows restore must skip (never write, never reject for),
# while corrupt files and the write-boundary check keep rejecting.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-backup-restore-keychain.XXXXXX")
trap 'rm -rf -- "$build"' EXIT HUP INT TERM
python3 - "$repo" "$build" <<'PYGEN'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
s = (root / 'src/settings/ApolloBackupRestore.m').read_text()
identity = s.split('static BOOL ApolloBackupOwnsKeychainIdentity', 1)[1].split("// Capture Apollo's Valet keychain items", 1)[0]
filters = s.split('static NSArray<NSDictionary *> *ApolloBackupValidatedKeychainItems', 1)[1].split('// Read every original before changing any item.', 1)[0]
code = ('static BOOL ApolloBackupOwnsKeychainIdentity' + identity +
        'static NSArray<NSDictionary *> *ApolloBackupValidatedKeychainItems' + filters)
test = (root / 'tests/backup_restore_keychain_tests.m').read_text()
(output / 'BackupRestoreKeychain.m').write_text(test.replace('// PRODUCTION_FILTERS', code))
PYGEN
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$build/BackupRestoreKeychain.m" -o "$build/tests"
"$build/tests"

#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
controller="$repo/src/settings/ApolloAutomaticBackupViewController.m"
store="$repo/src/settings/ApolloICloudBackupStore.m"
checklist="$repo/tests/icloud_backup_manual_checklist.md"

grep -Fq 'initForExportingURLs:@[templateURL] asCopy:NO' "$controller"
if grep -Fq 'initForExportingURLs:@[templateURL] asCopy:YES' "$controller"; then
    echo "folder picker must move, not copy, to receive an iOS security-scoped URL" >&2
    exit 1
fi
grep -Fq 'Files did not grant ongoing access to that folder' "$store"
grep -Fq 'NSURLBookmarkResolutionWithoutImplicitStartAccessing' "$store"
grep -Fq 'selected-folder permission is temporary' "$controller"
grep -Fq 'bookmark scope is ephemeral' "$checklist"
echo "iCloud folder picker policy checks passed (6)"

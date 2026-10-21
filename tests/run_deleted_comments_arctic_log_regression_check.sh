#!/bin/sh
set -eu

test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$test_root/src/ApolloDeletedCommentsData.m"

unsafe_log='ApolloLog(@"[DeletedComments] Warming Arctic cache for %@ (%@)", capturedLinkFullName, capturedSource);'
safe_log='os_log_info(ApolloFixLog(), "[ApolloFix] [DeletedComments] Warming Arctic cache for %{public}s (%{public}s)",'

if grep -F "$unsafe_log" "$source_file" >/dev/null; then
    echo 'FAIL: asynchronous Arctic warm diagnostics still format captured objects with %@' >&2
    exit 1
fi

if ! grep -F "$safe_log" "$source_file" >/dev/null; then
    echo 'FAIL: Arctic warm diagnostics do not use direct UTF-8 os_log formatting' >&2
    exit 1
fi

if ! grep -F '[capturedLinkFullName UTF8String], [capturedSource UTF8String]);' "$source_file" >/dev/null; then
    echo 'FAIL: Arctic warm diagnostics still hand Objective-C objects to the formatter' >&2
    exit 1
fi

echo 'deleted_comments_arctic_log_regression_check passed'

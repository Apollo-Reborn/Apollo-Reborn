#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_source="$test_repo_root/src/ApolloDirectChatWeb.xm"
contains() {
    if command -v rg >/dev/null 2>&1; then rg -Fq "$1" "$2"; else grep -Fq "$1" "$2"; fi
}

# Contract guards for the browser bridge. These are intentionally source-level:
# Reddit's authenticated Chat DOM cannot be exercised in a host-side test, but
# each guard protects a privacy/correctness boundary from accidental broadening.
contains '/_matrix/client/v3/rooms/' "$test_source"
contains '/chat/user/' "$test_source"
contains '/chat/threads/' "$test_source"
contains "payload?.msgtype!=='m.text'||payload.body!==lastNonempty.text" "$test_source"
contains "lastNonempty" "$test_source"
contains "Date.now()-current.at>750" "$test_source"
contains "current.serial<=lastNonempty.serial" "$test_source"
contains "lastNonempty?.serial===c.serial)lastNonempty=null" "$test_source"
contains "retryCandidate.txnId===txnId" "$test_source"
contains "retryCandidate.serial===lastNonempty.serial" "$test_source"
contains "retryCandidate.serial!==lastNonempty.serial" "$test_source"
contains "Date.now()-retryCandidate.failedAt<=10000" "$test_source"
contains "if(!retryLive){lastNonempty=null;retryCandidate=null}" "$test_source"
contains "instanceof Request?request.url:String(request)" "$test_source"
contains "stringByRemovingPercentEncoding" "$test_source"
contains 'requestId:`send-${Date.now()}-${++requestSerial}`' "$test_source"
contains "notify('failed',c)" "$test_source"
contains "draftEmptyClearGenerations" "$test_source"
contains "draftContentGenerations" "$test_source"
contains "ApolloMessageDraftShouldClearForSendGeneration" "$test_source"
contains "ApolloMessageDraftShouldInvalidateEmptyClearForSendGeneration" "$test_source"
contains "ApolloMessageDraftSendOwnsContentGeneration" "$test_source"
contains "draftRestoreAttemptedKeys" "$test_source"
contains "if(!composer(e))continue" "$test_source"
contains "composed:true" "$test_source"
contains "composer-type')==='thread" "$test_source"
contains "ApolloDirectChatLoadDraft" "$test_source"
contains "ApolloMessageDraftStoreAsync" "$test_source"
contains "Discarded debounced write" "$test_source"
contains "UDKeyUseModernRedditChat" "$test_source"
printf '%s\n' 'direct_chat_draft_source_tests: all 31 guards passed'

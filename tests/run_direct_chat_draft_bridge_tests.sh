#!/bin/sh
set -eu
node "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/direct_chat_draft_bridge_tests.js"

#!/bin/sh
set -eu
node "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/issue_log_check_tests.js"

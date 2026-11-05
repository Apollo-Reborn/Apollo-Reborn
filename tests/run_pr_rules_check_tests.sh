#!/bin/sh
set -eu
node "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/pr_rules_check_tests.js"

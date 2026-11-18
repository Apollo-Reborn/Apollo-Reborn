#!/bin/sh
set -eu
node "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/issue_device_label_tests.js"

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-sim-temp-safety.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

sentinel="$test_root/sentinel"
command_link="$test_root/command"
printf 'unchanged\n' > "$sentinel"
ln -s "$sentinel" "$command_link"

if python3 "$repo_root/scripts/capture-ipad-pane-state.py" \
    --device invalid-test-device \
    --work-dir "$test_root/work" \
    --command-file "$command_link" \
    >"$test_root/capture.out" 2>"$test_root/capture.err"; then
    printf 'capture accepted a symlinked command file\n' >&2
    exit 1
fi
grep -F 'Refusing unsafe simulator command file' "$test_root/capture.err" >/dev/null
test "$(cat "$sentinel")" = unchanged

hardlink="$test_root/hardlink-command"
ln "$sentinel" "$hardlink"
if python3 "$repo_root/scripts/capture-ipad-pane-state.py" \
    --device invalid-test-device \
    --work-dir "$test_root/hardlink-work" \
    --command-file "$hardlink" \
    >"$test_root/hardlink.out" 2>"$test_root/hardlink.err"; then
    printf 'capture accepted a hard-linked command file\n' >&2
    exit 1
fi
grep -F 'Refusing unsafe simulator command file' "$test_root/hardlink.err" >/dev/null
test "$(cat "$sentinel")" = unchanged

writable_command="$test_root/writable-command"
printf 'safe-looking\n' > "$writable_command"
chmod 0666 "$writable_command"
if python3 "$repo_root/scripts/capture-ipad-pane-state.py" \
    --device invalid-test-device \
    --work-dir "$test_root/writable-work" \
    --command-file "$writable_command" \
    >"$test_root/writable.out" 2>"$test_root/writable.err"; then
    printf 'capture accepted a group/other-writable command file\n' >&2
    exit 1
fi
grep -F 'Refusing unsafe simulator command file' "$test_root/writable.err" >/dev/null
test "$(cat "$writable_command")" = safe-looking

python3 -m py_compile "$repo_root/scripts/capture-ipad-pane-state.py"
bash -n "$repo_root/scripts/run-in-sim.sh"
# These are literal source-pattern checks, not shell expansions.
# shellcheck disable=SC2016
grep -F 'mktemp -d "${TMPDIR:-/tmp}/apollo-sim-inject.XXXXXX"' \
    "$repo_root/scripts/run-in-sim.sh" >/dev/null
# shellcheck disable=SC2016
grep -F 'install -m 600 "$DYLIB_DST" "$DYLIB_INJECT"' \
    "$repo_root/scripts/run-in-sim.sh" >/dev/null
# shellcheck disable=SC2016
if grep -F 'ApolloRebornSim-${DEV}' "$repo_root/scripts/run-in-sim.sh" >/dev/null; then
    printf 'legacy predictable fallback dylib path remains\n' >&2
    exit 1
fi

printf 'simulator temporary-path safety tests passed\n'

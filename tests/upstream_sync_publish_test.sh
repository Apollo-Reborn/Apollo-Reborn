#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

WORKFLOW="$ROOT/.github/workflows/boneman-upstream-sync.yml"
grep -F 'secrets.BONEMAN_UPSTREAM_SYNC_TOKEN' "$WORKFLOW" >/dev/null
grep -F 'run: scripts/publish-upstream-sync-review.sh' "$WORKFLOW" >/dev/null
if grep -F 'secrets.GITHUB_TOKEN' "$WORKFLOW" >/dev/null; then
  printf 'upstream sync workflow must not fall back to GITHUB_TOKEN for publication\n' >&2
  exit 1
fi

FAKE_BIN="$TEST_ROOT/bin"
FAKE_LOG="$TEST_ROOT/calls.log"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/git" <<'SH'
#!/usr/bin/env bash
printf 'git' >> "$FAKE_LOG"
printf ' <%s>' "$@" >> "$FAKE_LOG"
printf '\n' >> "$FAKE_LOG"
SH

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh' >> "$FAKE_LOG"
printf ' <%s>' "$@" >> "$FAKE_LOG"
printf '\n' >> "$FAKE_LOG"
if [[ "$*" == *"--method GET"* ]]; then
  printf '%s\n' "${FAKE_EXISTING:-}"
elif [[ "$*" == *"--method POST"* ]]; then
  printf 'https://github.com/Thetromboneman1/Apollo-Reborn/pull/42\n'
fi
SH

chmod +x "$FAKE_BIN/git" "$FAKE_BIN/gh"

run_publish() {
  env \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_EXISTING="${FAKE_EXISTING:-}" \
    GH_TOKEN="test-token" \
    BRANCH="Thetromboneman1/upstream-sync-0123456789ab" \
    UPSTREAM_SHA="0123456789abcdef" \
    DOWNSTREAM_BRANCH="main" \
    GITHUB_REPOSITORY="Thetromboneman1/Apollo-Reborn" \
    GITHUB_REPOSITORY_OWNER="Thetromboneman1" \
    UPSTREAM_REPOSITORY="Apollo-Reborn/Apollo-Reborn" \
    CONFLICTED="${CONFLICTED:-false}" \
    CONFLICT_FILES="${CONFLICT_FILES:-}" \
    "$ROOT/scripts/publish-upstream-sync-review.sh"
}

missing_output="$TEST_ROOT/missing.out"
if env -u GH_TOKEN "$ROOT/scripts/publish-upstream-sync-review.sh" >"$missing_output" 2>&1; then
  printf 'missing-token case unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'requires GH_TOKEN' "$missing_output" >/dev/null

: > "$FAKE_LOG"
FAKE_EXISTING="https://github.com/Thetromboneman1/Apollo-Reborn/pull/41" run_publish >"$TEST_ROOT/existing.out"
grep -F 'Reusing upstream review pull request' "$TEST_ROOT/existing.out" >/dev/null
grep -F 'git <push> <--set-upstream> <origin> <Thetromboneman1/upstream-sync-0123456789ab>' "$FAKE_LOG" >/dev/null
grep -F 'gh <api> <--method> <GET>' "$FAKE_LOG" >/dev/null
if grep -F '<POST>' "$FAKE_LOG" >/dev/null; then
  printf 'existing-PR case unexpectedly created a pull request\n' >&2
  exit 1
fi

: > "$FAKE_LOG"
FAKE_EXISTING='' run_publish >"$TEST_ROOT/create.out"
grep -F 'Created upstream review pull request' "$TEST_ROOT/create.out" >/dev/null
grep -F 'gh <api> <--method> <POST>' "$FAKE_LOG" >/dev/null
grep -F '<head=Thetromboneman1/upstream-sync-0123456789ab>' "$FAKE_LOG" >/dev/null
grep -F '<base=main>' "$FAKE_LOG" >/dev/null
expected_body="<body=Merges \`Apollo-Reborn/Apollo-Reborn@0123456789abcdef\` through the downstream package validation contract.>"
grep -F "$expected_body" "$FAKE_LOG" >/dev/null

: > "$FAKE_LOG"
CONFLICTED=true \
CONFLICT_FILES='src/Tweak.xm,src/settings/CustomAPIViewController.m' \
FAKE_EXISTING='' \
run_publish >"$TEST_ROOT/conflict-create.out"
grep -F 'Created upstream review pull request' "$TEST_ROOT/conflict-create.out" >/dev/null
grep -F '<draft=true>' "$FAKE_LOG" >/dev/null
grep -F '<title=chore: resolve Apollo-Reborn/Apollo-Reborn sync conflicts>' "$FAKE_LOG" >/dev/null
grep -F '<body=Reviews `Apollo-Reborn/Apollo-Reborn@0123456789abcdef` against downstream customizations. Automatic merge conflicts: `src/Tweak.xm,src/settings/CustomAPIViewController.m`. Resolve locally, preserve both contracts, and run the downstream validation before marking this ready.>' "$FAKE_LOG" >/dev/null

printf 'upstream sync publication tests passed\n'

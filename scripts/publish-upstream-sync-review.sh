#!/usr/bin/env bash
set -euo pipefail

required=(
  GH_TOKEN
  BRANCH
  UPSTREAM_SHA
  DOWNSTREAM_BRANCH
  GITHUB_REPOSITORY
  GITHUB_REPOSITORY_OWNER
  UPSTREAM_REPOSITORY
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'upstream sync publication requires %s\n' "$name" >&2
    exit 2
  fi
done

git push --set-upstream origin "$BRANCH"

existing=$(gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls" \
  -f state=open \
  -f "head=${GITHUB_REPOSITORY_OWNER}:${BRANCH}" \
  -f "base=${DOWNSTREAM_BRANCH}" \
  -f per_page=1 \
  --jq '.[0].html_url // empty')

if [[ -n "$existing" ]]; then
  printf 'Reusing upstream review pull request: %s\n' "$existing"
  exit 0
fi

if [[ "${CONFLICTED:-false}" == true ]]; then
  title="chore: resolve ${UPSTREAM_REPOSITORY} sync conflicts"
  body="Reviews \`${UPSTREAM_REPOSITORY}@${UPSTREAM_SHA}\` against downstream customizations. Automatic merge conflicts: \`${CONFLICT_FILES:-not reported}\`. Resolve locally, preserve both contracts, and run the downstream validation before marking this ready."
  created=$(gh api --method POST "repos/${GITHUB_REPOSITORY}/pulls" \
    -f "title=${title}" \
    -f "head=${BRANCH}" \
    -f "base=${DOWNSTREAM_BRANCH}" \
    -f "body=${body}" \
    -F draft=true \
    --jq '.html_url')
else
  title="chore: sync ${UPSTREAM_REPOSITORY} main"
  body="Merges \`${UPSTREAM_REPOSITORY}@${UPSTREAM_SHA}\` through the downstream package validation contract."
  created=$(gh api --method POST "repos/${GITHUB_REPOSITORY}/pulls" \
    -f "title=${title}" \
    -f "head=${BRANCH}" \
    -f "base=${DOWNSTREAM_BRANCH}" \
    -f "body=${body}" \
    --jq '.html_url')
fi

printf 'Created upstream review pull request: %s\n' "$created"

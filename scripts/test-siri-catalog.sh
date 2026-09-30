#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t apollo-catalog-tests)"
trap 'rm -rf -- "$WORK"' EXIT
xcrun swiftc -swift-version 6 "$ROOT/siri/Sources/Content/ApolloContentCatalog.swift" \
    "$ROOT/siri/Sources/Content/ApolloSessionContext.swift" \
    "$ROOT/siri/CatalogTests/main.swift" -o "$WORK/catalog-tests"
"$WORK/catalog-tests"
xcrun swiftc -swift-version 6 -parse-as-library \
    "$ROOT/siri/Sources/Content/ApolloPublicationGate.swift" \
    "$ROOT/siri/CatalogTests/PublicationGateTests.swift" -o "$WORK/publication-tests"
"$WORK/publication-tests"

#!/bin/sh
# Regenerates every tools/t3ref output and fails when the committed copy drifts.
set -eu
cd "$(dirname "$0")/../.."
python3 tools/t3ref/gen-tokens.py >/dev/null
mkdir -p Tests/InfinitusCoreTests/Fixtures/t3
cp tools/t3ref/upstream/tokens.resolved.json Tests/InfinitusCoreTests/Fixtures/t3/tokens.resolved.json
python3 tools/t3ref/gen-lucide.py >/dev/null
git diff --exit-code -- Sources/InfinitusUI/T3/*.generated.swift Sources/InfinitusCore/T3/*.generated.swift tools/t3ref/upstream/tokens.resolved.json Tests/InfinitusCoreTests/Fixtures/t3

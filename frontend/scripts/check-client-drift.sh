#!/usr/bin/env bash
# check-client-drift.sh — CI drift check for the generated OpenAPI TypeScript client.
#
# Regenerates types/api.ts from the committed openapi.json snapshot and
# fails if the result differs from what is committed.
# Run: bash scripts/check-client-drift.sh
set -euo pipefail

GENERATED_FILE="types/api.ts"
OPENAPI_SNAPSHOT="openapi.json"

echo "[drift-check] Regenerating $GENERATED_FILE from $OPENAPI_SNAPSHOT..."
bunx openapi-typescript "$OPENAPI_SNAPSHOT" -o "$GENERATED_FILE.tmp"

if diff -q "$GENERATED_FILE" "$GENERATED_FILE.tmp" > /dev/null 2>&1; then
  echo "[drift-check] OK — generated client matches committed snapshot."
  rm "$GENERATED_FILE.tmp"
  exit 0
else
  echo "[drift-check] DRIFT DETECTED — $GENERATED_FILE is stale."
  echo "Run: bunx openapi-typescript openapi.json -o types/api.ts"
  echo "Then commit the updated types/api.ts."
  diff "$GENERATED_FILE" "$GENERATED_FILE.tmp" || true
  rm "$GENERATED_FILE.tmp"
  exit 1
fi

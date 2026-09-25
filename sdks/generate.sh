#!/bin/sh
# Regenerates the three BEAI SDKs from api/openapi.v1.json. Generated output is
# never hand-edited: change the spec (or this script), then rerun.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SPEC="$ROOT/api/openapi.v1.json"
VERSION=$(tr -d '[:space:]' < "$ROOT/api/VERSION")

if [ ! -f "$SPEC" ]; then
  echo "ERROR: $SPEC not found" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The generator CLI is a locked dependency (tools/openapi-generator/bun.lock),
# never a floating `bunx pkg@version`. The jar it downloads is pinned in
# sdks/openapitools.json.
(cd "$ROOT/tools/openapi-generator" && bun install --frozen-lockfile >/dev/null)
GENERATOR="$ROOT/tools/openapi-generator/node_modules/.bin/openapi-generator-cli"

cd "$ROOT/sdks"

# Skip docs and tests: they multiply the tree size without adding runtime code.
SKIP="apiTests=false,modelTests=false,apiDocs=false,modelDocs=false"

generate() {
  name=$1
  spec=$2
  shift 2
  rm -rf "$name"
  "$GENERATOR" --openapitools ./openapitools.json generate \
    -i "$spec" -o "$name" --global-property "$SKIP" "$@" >/dev/null
  # Generator bookkeeping that embeds nothing useful and churns diffs.
  rm -rf "$name/.openapi-generator" "$name/.openapi-generator-ignore" "$name/git_push.sh"
  # CI templates for a standalone package repo: unused here, and the nested
  # workflow would contradict the wrapper's SHA-pinning standard.
  rm -rf "$name/.github" "$name/.travis.yml" "$name/.gitlab-ci.yml"
  echo "generated sdks/$name"
}

# Generator 7.25.0 mishandles a schema typed `null` (the api's `errors: null`
# problem details): python aborts and typescript-fetch imports a missing
# `./Null` model. Feed all three a `["string", "null"]` equivalent (the spec is
# OpenAPI 3.1, where `nullable` is not a keyword).
python3 - "$SPEC" "$TMP/openapi.json" <<'PY'
import json
import sys


def fix(node):
    if isinstance(node, dict):
        if node.get("type") == "null" and len(node) == 1:
            node.clear()
            node.update({"type": ["string", "null"]})
        for value in list(node.values()):
            fix(value)
    elif isinstance(node, list):
        for value in node:
            fix(value)


with open(sys.argv[1]) as source:
    spec = json.load(source)
fix(spec)
with open(sys.argv[2], "w") as target:
    json.dump(spec, target, indent=2, sort_keys=True)
PY

generate typescript "$TMP/openapi.json" -g typescript-fetch \
  --additional-properties="npmName=@beai/sdk,npmVersion=$VERSION,supportsES6=true,typescriptThreePlus=true"

# Bun is the only package manager we run: the generator's `prepare` script
# would shell out to npm on every install, and its README tells maintainers to
# use npm. Rewrite both deterministically. (The consumer-facing
# `npm install @beai/sdk` line stays: consumers choose their own manager.)
python3 - typescript <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
package = root / "package.json"
package.write_text(package.read_text().replace('"prepare": "npm run build"', '"prepare": "bun run build"'))
readme = root / "README.md"
text = readme.read_text()
text = text.replace("you need to have Node.js and npm installed", "you need to have Bun installed")
text = text.replace("npm install\nnpm run build", "bun install\nbun run build")
text = text.replace("publish it to npm:\n\n```bash\nnpm publish", "publish it to npm:\n\n```bash\nbun publish")
readme.write_text(text)
PY

generate php "$TMP/openapi.json" -g php \
  --additional-properties="composerVendorName=beai,composerProjectName=beai-php,packageName=Beai,invokerPackage=Beai,artifactVersion=$VERSION"

generate python "$TMP/openapi.json" -g python \
  --additional-properties="packageName=beai,projectName=beai,packageVersion=$VERSION"

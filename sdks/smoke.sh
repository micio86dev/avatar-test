#!/bin/sh
# Smoke checks over the generated SDKs: they must typecheck/parse, a client
# must be constructible, and the TypeScript client must send the bearer
# credential. Does not call the network. Every check fails when it found
# nothing to check.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
(cd "$ROOT/tools/openapi-generator" && bun install --frozen-lockfile >/dev/null)
TSC="$ROOT/tools/openapi-generator/node_modules/.bin/tsc"
cd "$ROOT/sdks"

(cd typescript && "$TSC" --noEmit -p tsconfig.json)
(cd typescript && bun -e "
import { Configuration, InterviewApi, OrganizationApi } from './src/index'
const api = new InterviewApi(new Configuration({ basePath: 'https://api.example.test' }))
if (!(api instanceof InterviewApi)) throw new Error('InterviewApi not constructible')

const seen: string[] = []
const fetchApi = async (_url: RequestInfo | URL, init?: RequestInit) => {
  seen.push(new Headers(init?.headers).get('Authorization') ?? '')
  return new Response(JSON.stringify({}), { status: 200, headers: { 'Content-Type': 'application/json' } })
}
const withKey = new OrganizationApi(new Configuration({ basePath: 'https://api.example.test', accessToken: 'beai_test_abc', fetchApi }))
await withKey.publicApiOrganizationShowRaw()
const withoutKey = new OrganizationApi(new Configuration({ basePath: 'https://api.example.test', fetchApi }))
await withoutKey.publicApiOrganizationShowRaw()
if (seen[0] !== 'Bearer beai_test_abc') throw new Error('bearer credential not sent: ' + JSON.stringify(seen[0]))
if (seen[1] !== '') throw new Error('Authorization sent without a credential: ' + JSON.stringify(seen[1]))
console.log('typescript: client instantiated, bearer credential sent')
")

if ! command -v php >/dev/null 2>&1; then
  echo "ERROR: php is not on PATH; cannot lint the PHP SDK" >&2
  exit 1
fi
php_files=$(find php -name '*.php' | wc -l | tr -d ' ')
if [ "$php_files" -eq 0 ]; then
  echo "ERROR: no PHP files found under sdks/php" >&2
  exit 1
fi
find php -name '*.php' -exec sh -c 'for f; do php -l "$f" >/dev/null || exit 1; done' sh {} +
echo "php: $php_files files, syntax ok"

python3 -B -c "
import ast, pathlib, sys
files = list(pathlib.Path('python').rglob('*.py'))
if not files:
    sys.exit('ERROR: no Python files found under sdks/python')
for f in files:
    ast.parse(f.read_text(), str(f))
print('python: %d files parsed' % len(files))
"

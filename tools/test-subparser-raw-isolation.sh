#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$root"
export ABLA_SYSROOT="$root"
cases="$root/tests/cases/subparser-raw-isolation"
out="$root/build/subparser-raw-isolation"
mkdir -p "$out"

"$compiler" build "$cases/valid.ab" --fast -o "$out/valid"
"$out/valid"
"$compiler" build "$cases/valid.ab" --fast -o "$out/valid"
"$out/valid"

for case in local transitive/main; do
    output="$out/${case//\//-}"
    "$compiler" build "$cases/$case.ab" --fast -o "$output"
    "$output"
done

check_failure() {
    local case=$1 expected=$2 log="$out/$1.log"
    if "$compiler" build "$cases/$case.ab" --fast -o "$out/$case" >"$log" 2>&1; then
        echo "raw isolation: $case compiled" >&2
        return 1
    fi
    local errors
    errors=$(grep '^error\[' "$log" || true)
    if [[ $errors != "$expected" ]]; then
        cat "$log" >&2
        return 1
    fi
    grep -qF "source[extension-expression]:$cases/$case.ab:" "$log"
}
check_failure malformed 'error[E_SUBPARSER_FAILURE]: invalid raw test literal'
check_failure unterminated 'error[E_SUBPARSER_FAILURE]: unterminated raw test literal'
sema_arity=$'\nerror[E_SEMANTIC]: function.arity:parserExpect'
for tier in interp bridge; do
    ABLA_COMPILE_EVAL=$tier check_failure arity-missing \
        'error[E_EVAL_INTRINSIC_ARITY]: parserExpect expects 2 arguments, got 1'"$sema_arity"
    ABLA_COMPILE_EVAL=$tier check_failure arity-extra \
        'error[E_EVAL_INTRINSIC_ARITY]: parserExpect expects 2 arguments, got 3'"$sema_arity"
done
echo 'raw isolation: opaque text, local and transitive discovery, nested holes, and bounded recovery'

stdlib="$out/stdlib"
mkdir -p "$stdlib/abla/raw-isolation-test"
for entry in "$root"/stdlib/*; do
    [[ ${entry##*/} == abla ]] || ln -sfn "$entry" "$stdlib/${entry##*/}"
done
for entry in "$root"/stdlib/abla/*; do
    ln -sfn "$entry" "$stdlib/abla/${entry##*/}"
done
cp "$cases/provider.ab" "$stdlib/abla/raw-isolation-test/entry.ab"

ABLA_STDLIB="$stdlib" node --input-type=module - "$compiler" "$cases" <<'JS'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const [compiler, root] = process.argv.slice(2);
const uri = pathToFileURL(path.join(root, 'valid.ab')).href;
const standard = fs.readFileSync(path.join(root, 'valid.ab'), 'utf8')
    .replace('import "provider.ab"', 'import "abla/raw-isolation-test"');
const opaque = 'import "provider.ab"\nfun main(): int { val value = $rawTest {plain}; 0 }\n';
const requests = [
    ['initialize', { workspaceRoots: [root], analysisMode: 'graph-v2' }],
    ['document/open', { uri, version: 1, text: standard }],
    ['analyze', {}],
    ['document/change', { uri, version: 2, text: standard.replace('tailAnswer() ==', 'tailAnswer() + 0 ==') }],
    ['analyze', {}],
    ['document/change', { uri, version: 3, text: opaque }],
    ['analyze', {}],
    ['shutdown', {}],
];
const input = requests.map(([method, params], index) =>
    JSON.stringify({ schema: 1, id: index + 1, method, params })).join('\n') + '\n';
const analysis = spawnSync(compiler, ['analyze', '--stdio'], {
    input, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
});
assert.equal(analysis.status, 0, analysis.stderr);
const responses = analysis.stdout.trim().split('\n').map(JSON.parse);
const document = id => {
    const response = responses.find(row => row.id === id);
    assert.ok(response?.result, JSON.stringify(response));
    const doc = response.result.documents.find(entry => entry.uri === uri);
    assert.ok(doc, JSON.stringify(response.result.documents.map(entry => entry.uri)));
    return doc;
};
for (const id of [3, 5]) {
    const doc = document(id);
    assert.deepEqual(doc.diagnostics, []);
    assert.ok(doc.symbols.some(symbol => symbol.name === 'main'));
}
const denied = document(7).diagnostics;
assert.equal(denied.length, 1, JSON.stringify(denied));
assert.equal(denied[0].code, 'W_SUBPARSER_NOT_EXPANDED');
JS
for tier in interp bridge; do
    ABLA_COMPILE_EVAL=$tier check_failure arity-missing \
        'error[E_EVAL_INTRINSIC_ARITY]: parserExpect expects 2 arguments, got 1'"$sema_arity"
    ABLA_COMPILE_EVAL=$tier check_failure arity-extra \
        'error[E_EVAL_INTRINSIC_ARITY]: parserExpect expects 2 arguments, got 3'"$sema_arity"
done
echo 'raw isolation: trusted editor expansion, overlay edit, and opaque local provider'

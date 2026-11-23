#!/usr/bin/env bash
# Opt-in $regex suggestions: real sema identities, original fix ranges and byte parity.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler=$root/$compiler
work=$(mktemp -d /tmp/abla-regex-construction.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp "$root/tests/cases/regex-construction/main.ab" "$work/main.ab"
fail() { printf 'regex-construction: %s\n' "$1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }
(cd "$work" && "$compiler" build main.ab -o program --fast) > "$work/off.log" 2>&1 || fail 'baseline did not build' "$work/off.log"
! grep -q W_REGEX_CONSTRUCTION "$work/off.log" || fail 'warning without opt-in' "$work/off.log"
cp "$work/program" "$work/baseline"
"$work/program" > "$work/before.out"
(cd "$work" && "$compiler" build main.ab -o program --fast --warn-regex-construction) > "$work/on.log" 2>&1 || fail 'opt-in did not build' "$work/on.log"
[[ $(grep -c W_REGEX_CONSTRUCTION "$work/on.log") == 3 ]] || fail 'expected three suggestions (digits, escaped, checked)' "$work/on.log"
! grep -q W_JSON_CONSTRUCTION "$work/on.log" || fail 'the regex flag asked for JSON suggestions' "$work/on.log"
cmp "$work/baseline" "$work/program" || fail 'lint changed emitted program bytes'
cat > "$work/requests.jsonl" <<JSON
{"schema":1,"id":1,"method":"initialize","params":{"workspaceRoots":["$work"],"clientName":"regex-construction","clientVersion":"1","analysisMode":"graph-v2","regexConstruction":true}}
{"schema":1,"id":2,"method":"analyze","params":{"roots":["$work/main.ab"]}}
{"schema":1,"id":3,"method":"shutdown","params":{}}
JSON
"$compiler" analyze --stdio < "$work/requests.jsonl" > "$work/answers.jsonl" 2> "$work/editor.err"
node --input-type=module - "$work" <<'NODE'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root=process.argv[2];
const answers=fs.readFileSync(root+'/answers.jsonl','utf8').trim().split('\n').map(JSON.parse);
const answer=answers.find(a=>a.id===2);
assert.equal(answer.error,undefined,JSON.stringify(answer));
const doc=answer.result.documents.find(d=>d.uri.endsWith('/main.ab'));
const bytes=Buffer.from(doc.text);
const owner=d=>[...bytes.subarray(0,d.range.start).toString().matchAll(/\bfun\s+(\w+)/g)].at(-1)?.[1];
const warnings=doc.diagnostics.filter(d=>d.code==='W_REGEX_CONSTRUCTION');
assert.deepEqual(warnings.map(owner).sort(),['checked','digits','escaped'],JSON.stringify(doc.diagnostics));
for(const d of warnings)assert.equal(d.severity,'warning');
const fixed=warnings.filter(d=>d.fixes?.length);
assert.deepEqual(fixed.map(owner),['digits'],'only the .regex form with an unescaped pattern gets an edit');
const edit=fixed[0].fixes[0].edits[0];
assert.equal(edit.newText,'$regex("[0-9]+")');
fs.writeFileSync(root+'/fixed.ab',Buffer.concat([bytes.subarray(0,edit.range.start),Buffer.from(edit.newText),bytes.subarray(edit.range.end)]));
console.log('regex-construction: '+warnings.length+' suggestions; '+fixed.length+' fix');
NODE
(cd "$work" && "$compiler" build fixed.ab -o fixed --fast) > "$work/fixed.log" 2>&1 || fail 'fixed source did not build' "$work/fixed.log"
"$work/fixed" > "$work/fixed.out"
cmp "$work/before.out" "$work/fixed.out" || fail 'the fix changed the program output'
mkdir "$work/tests"
cp "$work/main.ab" "$work/tests/main.ab"
(cd "$work" && "$compiler" build tests/main.ab -o tests-program --fast --warn-regex-construction) > "$work/tests.log" 2>&1 || fail 'test fixture did not build' "$work/tests.log"
! grep -q W_REGEX_CONSTRUCTION "$work/tests.log" || fail 'warned in a test directory' "$work/tests.log"
echo 'regex-construction: opt-in, identities, exclusions, fix and byte parity passed'

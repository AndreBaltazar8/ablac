#!/usr/bin/env bash
# Opt-in suggestions: real sema identities, original fix ranges and byte parity.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler=$root/$compiler
work=$(mktemp -d /tmp/abla-json-construction.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp "$root/tests/cases/json-construction/main.ab" "$work/main.ab"
fail() { printf 'json-construction: %s\n' "$1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }
(cd "$work" && "$compiler" build main.ab -o program --fast) > "$work/off.log" 2>&1 || fail 'baseline did not build' "$work/off.log"
! grep -q W_JSON_CONSTRUCTION "$work/off.log" || fail 'warning without opt-in'
cp "$work/program" "$work/baseline"
"$work/program" > "$work/before.out"
(cd "$work" && "$compiler" build main.ab -o program --fast --warn-json-construction) > "$work/on.log" 2>&1 || fail 'opt-in did not build' "$work/on.log"
grep -q W_JSON_CONSTRUCTION "$work/on.log" || fail 'opt-in gave no suggestions' "$work/on.log"
cmp "$work/baseline" "$work/program" || fail 'lint changed emitted program bytes'
"$work/program" > "$work/after.out"
cmp "$work/before.out" "$work/after.out" || fail 'lint changed program behavior'
node --input-type=module - "$work" <<'NODE'
import fs from 'node:fs';
const root=process.argv[2];
fs.writeFileSync(root+'/overload.ab','import "abla/json"\nfun jsonStringify(value: int): string = "custom"\nfun payload(n: int): string = "{\\"n\\":${n}}"\nfun main: int = 0\n');
const lines=[{schema:1,id:1,method:'initialize',params:{workspaceRoots:[root],clientName:'json-construction',clientVersion:'1',analysisMode:'graph-v2',jsonConstruction:true}},
 {schema:1,id:2,method:'analyze',params:{roots:[root+'/main.ab']}},
 {schema:1,id:3,method:'analyze',params:{roots:[root+'/overload.ab']}},{schema:1,id:4,method:'shutdown',params:{}}];
fs.writeFileSync(root+'/requests.jsonl',lines.map(JSON.stringify).join('\n')+'\n');
NODE
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
const owner=d=>{const prefix=bytes.subarray(0,d.range.start).toString();return [...prefix.matchAll(/\bfun\s+(\w+)/g)].at(-1)?.[1];};
const warnings=doc.diagnostics.filter(d=>d.code==='W_JSON_CONSTRUCTION');
const names=warnings.map(owner).sort();
assert.deepEqual(names,['safe','concatenated','arrayValue','escaped','quoted','pretty','floating','shared','shadow','effect','writer','alias','terminal','branch'].sort(),JSON.stringify(doc.diagnostics));
for(const d of warnings){assert.equal(d.severity,'warning');assert.ok(!d.tags?.includes('unnecessary'));}
const fixed=warnings.filter(d=>d.fixes?.length);
assert.ok(fixed.some(d=>owner(d)==='safe'),'simple scalar template needs a fix');
assert.ok(fixed.some(d=>owner(d)==='escaped'),'already-standard-escaped string needs a fix');
assert.ok(fixed.some(d=>owner(d)==='writer'),'owned buffer run needs a streaming fix');
for(const d of fixed)assert.ok(['safe','concatenated','arrayValue','escaped','writer'].includes(owner(d)),'unsafe fix for '+owner(d));
const edits=fixed.flatMap(d=>d.fixes[0].edits).sort((a,b)=>b.range.start-a.range.start);
let result=bytes;
for(const e of edits){assert.ok(e.range.start>=0&&e.range.end<=bytes.length);result=Buffer.concat([result.subarray(0,e.range.start),Buffer.from(e.newText),result.subarray(e.range.end)]);}
fs.writeFileSync(root+'/fixed.ab',result);
const overloaded=answers.find(a=>a.id===3).result.documents.find(d=>d.uri.endsWith('/overload.ab'));
assert.ok(!overloaded.diagnostics.some(d=>d.severity==='error'),JSON.stringify(overloaded.diagnostics));
const refused=overloaded.diagnostics.filter(d=>d.code==='W_JSON_CONSTRUCTION');
assert.equal(refused.length,1,JSON.stringify(overloaded.diagnostics));
assert.ok(!refused[0].fixes?.length,'user serializer overload must suppress the fix');
console.log('json-construction: '+warnings.length+' warnings; '+fixed.length+' conservative fixes');
NODE
(cd "$work" && "$compiler" build fixed.ab -o fixed --fast) > "$work/fixed.log" 2>&1 || fail 'fixed source did not build' "$work/fixed.log"
"$work/fixed" > "$work/fixed.out"
cmp "$work/before.out" "$work/fixed.out" || fail 'fixes changed JSON bytes or effect ordering'
cat > "$work/literal.ab" <<'ABLA'
import "abla/json"
fun existing(n: int): Json = $json {"raw": "{\"n\":${n}}"}
fun main { val value = existing(1) }
ABLA
(cd "$work" && "$compiler" build literal.ab -o literal --fast --warn-json-construction) > "$work/literal.log" 2>&1 || fail 'existing JSON literal did not build' "$work/literal.log"
! grep -q W_JSON_CONSTRUCTION "$work/literal.log" || fail 'warned inside an existing JSON literal' "$work/literal.log"
mkdir "$work/tests"
cp "$work/main.ab" "$work/tests/main.ab"
(cd "$work" && "$compiler" build tests/main.ab -o tests-program --fast --warn-json-construction) > "$work/tests.log" 2>&1 || fail 'test fixture did not build' "$work/tests.log"
! grep -q W_JSON_CONSTRUCTION "$work/tests.log" || fail 'warned in a test directory' "$work/tests.log"
echo 'json-construction: opt-in, identities, exclusions, fixes and byte parity passed'

#!/usr/bin/env bash
# Report arithmetic controls; no compiler build, no timing claims.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jq -n '{schemaVersion:1,metadata:{},samples:[
 {kind:"runtime",program:"fannkuch",language:"c",wallSeconds:2,rssBytes:100},
 {kind:"runtime",program:"fannkuch",language:"c",wallSeconds:4,rssBytes:300},
 {kind:"runtime",program:"fannkuch",language:"abla",wallSeconds:8,rssBytes:400},
 {kind:"compile",program:"fannkuch",language:"c",wallSeconds:2},
 {kind:"compile",program:"fannkuch",language:"abla",wallSeconds:4},
 {kind:"size",program:"fannkuch",language:"c",rawBytes:12,strippedBytes:10},
 {kind:"size",program:"fannkuch",language:"abla",rawBytes:22,strippedBytes:20}]}' > "$work/raw.json"
jq -f "$root/tools/bench-languages/summarize.jq" "$work/raw.json" > "$work/results.json"
check='.programs.fannkuch.languages | .c.wallSeconds=={median:3,min:2,max:4} and .abla.ratiosToC.wallSeconds==8/3 and .abla.ratiosToC.rssBytes==2 and .abla.ratiosToC.compileSeconds==2 and .abla.ratiosToC.strippedBytes==2'
jq -e "$check" "$work/results.json" >/dev/null
# An altered observation MUST break the expected ratio.
jq '(.samples[]|select(.language=="abla" and .kind=="runtime").wallSeconds)=80' "$work/raw.json" | jq -f "$root/tools/bench-languages/summarize.jq" > "$work/mutated.json"
if jq -e "$check" "$work/mutated.json" >/dev/null; then echo 'ratio mutation escaped' >&2; exit 1; fi
# Startup and throughput use their own units and directions. All raw metrics
# remain in seconds/bytes; only the rendered table rounds values.
jq '.samples += [
 {kind:"runtime",program:"hello",language:"c",wallSeconds:1,rssBytes:100},
 {kind:"runtime",program:"hello",language:"abla",wallSeconds:1,rssBytes:100},
 {kind:"compile",program:"hello",language:"c",wallSeconds:1},
 {kind:"compile",program:"hello",language:"abla",wallSeconds:1},
 {kind:"size",program:"hello",language:"c",rawBytes:10,strippedBytes:10},
 {kind:"size",program:"hello",language:"abla",rawBytes:10,strippedBytes:10},
 {kind:"startup",program:"hello",language:"c",wallSeconds:0.002},
 {kind:"startup",program:"hello",language:"abla",wallSeconds:0.001},
 {kind:"runtime",program:"http-echo",language:"c",wallSeconds:1,rssBytes:100,requestsPerSecond:100},
 {kind:"runtime",program:"http-echo",language:"abla",wallSeconds:0.5,rssBytes:100,requestsPerSecond:200},
 {kind:"compile",program:"http-echo",language:"c",wallSeconds:1},
 {kind:"compile",program:"http-echo",language:"abla",wallSeconds:1},
 {kind:"size",program:"http-echo",language:"c",rawBytes:10,strippedBytes:10},
 {kind:"size",program:"http-echo",language:"abla",rawBytes:10,strippedBytes:10}
]' "$work/raw.json" | jq -f "$root/tools/bench-languages/summarize.jq" > "$work/extra.json"
jq -e '.programs.hello.languages.abla.ratiosToC.startupSeconds==0.5 and .programs["http-echo"].languages.abla.ratiosToC.requestsPerSecond==2' "$work/extra.json" > /dev/null
"$root/tools/bench-languages/report.sh" "$work/extra.json" > "$work/extra.md"
rg -q '^\| abla \| 1 \| 0.5 \|$' "$work/extra.md"
rg -q '^\| abla \| 200 \| 2 \|$' "$work/extra.md"
if jq 'del(.samples[] | select(.kind=="compile"))' "$work/raw.json" | jq -f "$root/tools/bench-languages/summarize.jq" >/dev/null 2>&1; then
    echo 'missing compile samples escaped' >&2; exit 1
fi
# Zero C RSS is unavailable and cannot create infinity or a zero-memory ratio.
jq '(.samples[]|select(.language=="c" and .kind=="runtime").rssBytes)=0' "$work/raw.json" | jq -f "$root/tools/bench-languages/summarize.jq" | jq -e '.programs.fannkuch.languages.abla.ratiosToC.rssBytes==null' > /dev/null
"$root/tools/bench-languages/report.sh" "$work/results.json" > "$work/report.md"
rg -q 'Abla language benchmarks' "$work/report.md"
printf '%s\n' 1.274219991 > "$work/float.expected"
printf '%s\n' 1.2742199909 > "$work/float.actual"
"$root/tools/bench-languages/verify.sh" spectral-norm "$work/float.actual" "$work/float.expected"
for bad in 1.2743 NaN Infinity oops 1.274219991junk ''; do
    printf '%s\n' "$bad" > "$work/float.actual"
    if "$root/tools/bench-languages/verify.sh" spectral-norm "$work/float.actual" "$work/float.expected" 2>/dev/null; then
        echo "invalid float escaped: $bad" >&2; exit 1
    fi
done
printf '%s\n' '{"a":1,"b":"escaped\\n"}' > "$work/json.expected"
printf '%s\n' '{"b":"escaped\\n","a":1}' > "$work/json.actual"
"$root/tools/bench-languages/verify.sh" json "$work/json.actual" "$work/json.expected"
printf '%s\n' '{"a":2,"b":"escaped\\n"}' > "$work/json.actual"
if "$root/tools/bench-languages/verify.sh" json "$work/json.actual" "$work/json.expected" >/dev/null 2>&1; then
    echo 'changed JSON value escaped' >&2; exit 1
fi
echo 'benchmark report controls passed (including altered sample and zero-RSS controls)'

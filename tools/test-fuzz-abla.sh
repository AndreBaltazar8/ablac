#!/usr/bin/env bash
# The Abla port of the differential fuzzer (tools/fuzz), kept short for the suite: the PRNG's reference vectors and
# the comparison self-test, a planted disagreement that the minimiser must find and reduce, a check's own oracle
# failure and a shared non-zero exit through the real six-way runner, two fixed seeds, the recorded cases, and a
# wrong expectation that each oracle (drop logs, gzip, JSON, YAML) must report in every mode, and one seed of each
# campaign (hosted tasks, panics, hostless capabilities, shared globals, compile-time tiers, strict-versus-flat imports,
# module and subparser graphs with their cache
# phases, cross-target tiers, subparser refusals), and the regex campaign: abla/regex against the independent oracle on
# two fixed seeds, the oracle against the recorded Python results, and a planted oracle fault. Long
# campaigns run outside the suite (tools/fuzz/run --seeds ...), as does --integer-stores until every store site is refused.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
fuzz() { tools/fuzz/run --compiler "$compiler" "$@"; }

fuzz --selftest
fuzz --control-minimise

controls=build/fuzz-abla/controls
mkdir -p "$controls"
printf 'import "abla/io"\n\n@export("run")\nfun run(): int {\n    println("c0=FUZZ_ORACLE_FAILURE:control")\n    0\n}\n\nfun main: int = run()\n' \
    > "$controls/oracle.ab"
printf 'import "abla/io"\n\n@export("run")\nfun run(): int {\n    println("c0=1")\n    3\n}\n\nfun main: int = run()\n' \
    > "$controls/status.ab"
if output=$(fuzz --program "$controls/oracle.ab"); then
    echo "fuzz: a failed oracle line was not reported: $output" >&2
    exit 1
fi
[[ $output == *"result oracle failed"* ]] || { echo "fuzz: oracle control: $output" >&2; exit 1; }
if output=$(fuzz --program "$controls/status.ab"); then
    echo "fuzz: a shared non-zero exit was not reported: $output" >&2
    exit 1
fi
[[ $output == *"exited with status 3"* ]] || { echo "fuzz: status control: $output" >&2; exit 1; }
echo "fuzz: an oracle failure and a non-zero exit are reported through every mode"

fuzz --seeds 100000-100001 --checks 12
fuzz --replay
fuzz --control-oracle default_owner_check,ownership_lifetime_check,fresh_select_check,json_check,yaml_check,gzip_check,region_member_check
fuzz --hosted-tasks --seeds 100000 --checks 8
fuzz --panics --seeds 100008 --checks 2
fuzz --check-hostless-capabilities
fuzz --shared-globals --seeds 100000
fuzz --module-graphs --seeds 100002
fuzz --compile-time-tiers --seeds 100000 --checks 8
fuzz --strict-flat --seeds 100000-100001
fuzz --subparser-graphs --seeds 100001
fuzz --cross-target-tiers --seeds 100001
fuzz --check-subparser-refusals
fuzz --regex --seeds 100000-100001 --cases 1000
fuzz --control-regex
regex_corpus=build/fuzz-abla/regex-corpus.tsv
zcat tests/cases/regex/corpus.tsv.gz >"$regex_corpus"
fuzz --regex-corpus "$regex_corpus"

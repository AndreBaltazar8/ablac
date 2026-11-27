#!/usr/bin/env bash
# The Abla port of the differential fuzzer (tools/fuzz), kept short for the suite: the PRNG's reference vectors and
# the comparison self-test, a planted disagreement that the minimiser must find and reduce, a check's own oracle
# failure and a shared non-zero exit through the real six-way runner, two fixed seeds, the recorded cases, and a
# wrong expectation that each oracle (drop logs, gzip, JSON, YAML) must report in every mode, and one seed of each
# campaign (hosted tasks, panics, hostless capabilities, shared globals, compile-time tiers, strict-versus-flat imports, integer stores,
# module and subparser graphs with their cache
# phases, cross-target tiers, subparser refusals), and the regex campaign: abla/regex against the independent oracle on
# two fixed seeds, the oracle against the recorded Python results, and a planted oracle fault; and the editor's checked scalar bodies
# against full typing (tools/fuzz/analysis-scalar.mjs). Long
# campaigns run outside the suite (tools/fuzz/run --seeds ...).
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

# The build-file-relative paths axis (ABLA_FUZZ_BUILD_PATHS=1, tools/fuzz/build-paths.sh): a program built from four directories, the old
# working-directory reading and four escapes agree with every mode; a planted difference between the builds is reported.
printf 'import "abla/io"\n\n@export("run")\nfun run(): int {\n    println("c0=1")\n    0\n}\n\nfun main: int = run()\n' > "$controls/paths.ab"
ABLA_FUZZ_BUILD_PATHS=1 fuzz --program "$controls/paths.ab"
if output=$(ABLA_FUZZ_BUILD_PATHS=1 ABLA_FUZZ_BUILD_PATHS_PLANT=behaviour fuzz --program "$controls/paths.ab"); then
    echo "fuzz: a planted build-paths difference was not reported: $output" >&2
    exit 1
fi
[[ $output == *"build-paths"* ]] || { echo "fuzz: build-paths control: $output" >&2; exit 1; }
if output=$(ABLA_FUZZ_BUILD_PATHS=1 ABLA_FUZZ_BUILD_PATHS_PLANT=bytes fuzz --program "$controls/paths.ab"); then
    echo "fuzz: a planted build-paths byte difference was not reported: $output" >&2
    exit 1
fi
[[ $output == *"build-paths"* ]] || { echo "fuzz: build-paths bytes control: $output" >&2; exit 1; }
echo "fuzz: the build-paths axis agrees with the other modes and reports a planted difference in behaviour and in bytes"

fuzz --seeds 100000-100001 --checks 12
fuzz --replay
fuzz --control-oracle default_owner_check,ownership_lifetime_check,fresh_select_check,json_check,yaml_check,gzip_check,region_member_check,logical_assign_check,static_concat_check,gc_churn_check,sealed_when_check
fuzz --hosted-tasks --seeds 100000 --checks 8
fuzz --panics --seeds 100008 --checks 2
tools/fuzz/test-targets.sh "$compiler"
fuzz --check-hostless-capabilities
fuzz --shared-globals --seeds 100000
fuzz --module-graphs --seeds 100002
fuzz --compile-time-tiers --seeds 100000 --checks 8
fuzz --strict-flat --seeds 100000-100001
# A seed is one type (seed % 6: i8, u8, i16, u16, i32, u32), each in every site and value class, built three ways: all
# six were 131 of this test's 286 CPU-seconds. The suite takes i8 (100002) and u32 (100001), the narrowest signed and
# the widest unsigned; RUN_TESTS_FULL=1 (or FUZZ_STORES_FULL=1) takes all six.
if [[ -n ${FUZZ_STORES_FULL:-${RUN_TESTS_FULL:-}} ]]; then fuzz --integer-stores --seeds 100000-100005
else fuzz --integer-stores --seeds 100001-100002
fi
fuzz --subparser-graphs --seeds 100001
fuzz --cross-target-tiers --seeds 100001
fuzz --check-subparser-refusals
fuzz --regex --seeds 100000-100001 --cases 1000
fuzz --control-regex
regex_corpus=build/fuzz-abla/regex-corpus.tsv
zcat tests/cases/regex/corpus.tsv.gz >"$regex_corpus"
fuzz --regex-corpus "$regex_corpus"
# The editor's checked scalar bodies (#1132) against full typing over seeded edits: the planted difference always, the seeds in the full form
# (each seed is about 20 s of two editor services).
node tools/fuzz/analysis-scalar.mjs "$compiler" --control --work build/fuzz-analysis-scalar/control
if [[ -n ${RUN_TESTS_FULL:-} ]]; then node tools/fuzz/analysis-scalar.mjs "$compiler" --seeds 1-3 --edits 16; fi

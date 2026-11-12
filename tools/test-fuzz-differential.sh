#!/usr/bin/env bash
# A short seeded run of the differential fuzzer (tools/fuzz-differential): random
# well-typed programs must print the same and exit the same under native --fast,
# native release, the compile-time evaluator (interpreter and native code) and
# hostless WebAssembly (release and development modules). The seeds are fixed, so
# a failure reproduces; the self-test checks that a difference is reported.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
python3 tools/fuzz-differential --selftest
python3 - "$compiler" <<'PY'
import runpy, sys
f = runpy.run_path('tools/fuzz-differential')
lines, call, ty = f['Gen'](123).gzip_check(0)
runner = f['Runner'](sys.argv[1], 120)
def run(lines, name):
    return runner.all_modes('build/fuzz-differential/' + name,
                            (f['Gen'].PRELUDE, [(lines, call, ty, 0)]))
good = run(lines, 'gzip-control-good')
assert f['verdict'](good) is None, good
# Corrupt the decoded value seen by the check, across every execution mode.
broken = [s.replace('decoded.data != original', 'decoded.data + "x" != original') for s in lines]
assert broken != lines
bad = run(broken, 'gzip-control-broken')
assert all(v[0] != 'build-failed' for v in bad.values()), bad
assert all('c0=FUZZ_ORACLE_FAILURE' in v[0] for v in bad.values()), bad
assert f['verdict'](bad) is not None and f['differing_lines'](bad) == ['c0'], bad
print('fuzz differential: broken gzip round trip detected in all modes')
lines, call, ty = f['Gen'](321).json_check(0)
good = run(lines, 'json-control-good')
assert f['verdict'](good) is None, good
broken = [s + ' + "x"' if s.startswith('    val expected = ') else s for s in lines]
assert broken != lines
bad = run(broken, 'json-control-broken')
assert all(v[0] != 'build-failed' for v in bad.values()), bad
assert all('c0=FUZZ_ORACLE_FAILURE' in v[0] for v in bad.values()), bad
assert f['verdict'](bad) is not None and f['differing_lines'](bad) == ['c0'], bad
print('fuzz differential: wrong JSON expectation detected in all modes')
lines, call, ty = f['Gen'](4405).yaml_check(0)
good = run(lines, 'yaml-control-good')
assert f['verdict'](good) is None, good
broken = [s + ' + "x"' if s.startswith('    val expected = ') else s for s in lines]
assert broken != lines
bad = run(broken, 'yaml-control-broken')
assert all(v[0] != 'build-failed' for v in bad.values()), bad
assert all('c0=FUZZ_ORACLE_FAILURE' in v[0] for v in bad.values()), bad
assert f['verdict'](bad) is not None and f['differing_lines'](bad) == ['c0'], bad
print('fuzz differential: wrong YAML expectation detected in all modes')
lines, call, ty = f['Gen'](6001).default_owner_check(0)
good = run(lines, 'default-owner-control-good')
assert f['verdict'](good) is None, good
broken = [s.replace('if (actual != ', 'if (actual + "x" != ') for s in lines]
assert broken != lines
bad = run(broken, 'default-owner-control-broken')
assert all(v[0] != 'build-failed' and 'c0=FUZZ_ORACLE_FAILURE' in v[0] for v in bad.values()), bad
assert f['verdict'](bad) is not None, bad
print('fuzz differential: wrong default-owner expectation detected in all modes')
lines, call, ty = f['Gen'](7001).ownership_lifetime_check(0)
good = run(lines, 'ownership-lifetime-control-good')
assert f['verdict'](good) is None, good
broken = [s.replace('if (actual != ', 'if (actual + "x" != ') for s in lines]
assert broken != lines
bad = run(broken, 'ownership-lifetime-control-broken')
assert all(v[0] != 'build-failed' and 'c0=FUZZ_ORACLE_FAILURE' in v[0] for v in bad.values()), bad
assert f['verdict'](bad) is not None, bad
print('fuzz differential: wrong ownership-lifetime expectation detected in all modes')
lines, call, ty = f['Gen'](8001).fresh_select_check(0)
good = run(lines, 'fresh-select-control-good')
assert f['verdict'](good) is None, good
broken = [s.replace('if (actual != ', 'if (actual + "x" != ') for s in lines]
assert broken != lines
bad = run(broken, 'fresh-select-control-broken')
assert all(v[0] != 'build-failed' and 'c0=FUZZ_ORACLE_FAILURE:' in v[0] for v in bad.values()), bad
assert f['verdict'](bad) is not None, bad
print('fuzz differential: wrong fresh-selection expectation detected in all modes')
# Check the isolated shared-global campaign rejects an auto-only mismatch,
# while accepting complete agreement, without depending on the open #796 bug.
from types import SimpleNamespace
class FakeRunner:
    def __init__(self, broken): self.broken = broken
    def native(self, source, out, fast, mode):
        kind = source.rsplit('/', 1)[-1].removesuffix('.ab')
        expected = f['shared_global_program'](987654, kind)[1]
        return ('wrong\n', 0) if self.broken and kind == 'array' and mode == 'auto' else (expected, 0)
args = SimpleNamespace(keep=False)
assert f['run_shared_globals'](args, 987654, FakeRunner(False)) is None
failure = f['run_shared_globals'](args, 987654, FakeRunner(True))
assert failure and 'array/auto' in failure, failure
print('fuzz differential: shared-global mismatch is rejected')
lines, call, ty = f['Gen'](1).task_check(0)
def hosted(lines, name):
    return runner.all_modes('build/fuzz-differential/' + name,
                            (f['Gen'].PRELUDE_TASK, [(lines, call, ty, 0)]), include_wasm=False)
good = hosted(lines, 'task-control-good')
assert f['verdict'](good) is None, good
broken = [s.replace('if (actual != ', 'if (actual + "x" != ') for s in lines]
assert broken != lines
bad = hosted(broken, 'task-control-broken')
assert all(v[0] != 'build-failed' for v in bad.values()), bad
assert all('c0=FUZZ_ORACLE_FAILURE' in v[0] for v in bad.values()), bad
assert f['verdict'](bad) is not None and f['differing_lines'](bad) == ['c0'], bad
print('fuzz differential: wrong task expectation detected in all four hosted modes')
PY
python3 tools/fuzz-differential --compiler "$compiler" --seeds 1-2 --checks 16
python3 tools/fuzz-differential --compiler "$compiler" --hosted-tasks --seeds 1-2 --checks 8
python3 tools/fuzz-differential --compiler "$compiler" --check-hostless-capabilities
python3 tools/fuzz-differential --compiler "$compiler" --module-graphs --seeds 2
python3 tools/fuzz-differential --compiler "$compiler" --subparser-graphs --seeds 1
python3 tools/fuzz-differential --compiler "$compiler" --cross-target-tiers --seeds 1-2
python3 tools/fuzz-differential --compiler "$compiler" --check-subparser-refusals
# The cases the fuzzer found stay as programs: every mode must print the same, and
# a compile-time answer that differs from the run-time one prints MISMATCH.
for program in tests/cases/fuzz-differential/*.ab; do
    python3 tools/fuzz-differential --compiler "$compiler" --program "$program"
    if python3 tools/fuzz-differential --compiler "$compiler" --program "$program" --show | grep -q MISMATCH; then
        echo "fuzz differential: $program: compile time disagrees with run time" >&2
        exit 1
    fi
done
echo "fuzz differential: seeded programs and the recorded cases agree in every mode"

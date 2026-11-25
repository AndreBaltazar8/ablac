#!/usr/bin/env bash
# tools/release-check.sh, check `static-input`: with the dynamic asset beside the static default, the Linux job of the run must have logged the sha256 of the
# compiler its static step built from, equal to the published ablac-dynamic-x86_64-linux. A fake `gh` serves the job list and the log: an equal hash is a PASS, a
# different one a FAIL, a log without the line or no readable log a SKIP (not a failure of the check).
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "release-check static-input: $1" >&2; exit 1; }
cd "$work"
mkdir artifacts bin
printf '#!/bin/sh\necho "ablac 9.9.9"\n' > artifacts/ablac-dynamic-x86_64-linux
chmod +x artifacts/ablac-dynamic-x86_64-linux
cp artifacts/ablac-dynamic-x86_64-linux stage2
printf '#!/bin/sh\necho "ablac 9.9.9"\n# static\n' > artifacts/ablac-x86_64-linux
chmod +x artifacts/ablac-x86_64-linux
printf 'toolchain' > artifacts/abla-toolchain-x86_64-linux.tar.gz
for name in ablac-x86_64-linux ablac-dynamic-x86_64-linux abla-toolchain-x86_64-linux.tar.gz; do (cd artifacts && sha256sum "$name" > "$name.sha256"); done
ls artifacts | sort | grep -v '\.sha256$' > expected || true
dynamic_hash=$(sha256sum artifacts/ablac-dynamic-x86_64-linux | cut -d' ' -f1)
# The fake gh: `run view RUN -R REPO --json ...` prints the job table; `run view RUN -R REPO --job ID --log` prints $FAKE_GH_LOG (or fails with FAKE_GH_FAIL).
cat > bin/gh <<'GH'
#!/usr/bin/env bash
for argument in "$@"; do
    if [[ $argument == --log ]]; then
        [[ -z ${FAKE_GH_FAIL:-} ]] || exit 1
        cat "$FAKE_GH_LOG"
        exit 0
    fi
done
echo 4242
GH
chmod +x bin/gh
run() { # LOGFILE -> the output lines
    FAKE_GH_LOG=$1 PATH="$work/bin:$PATH" "$root/tools/release-check.sh" v9.9.9 1 stage2 --artifacts artifacts --assets-from expected --out "out-$RANDOM" --source-ref 0000000000000000000000000000000000000000 2>&1 || true
}
line() { grep -E "^(PASS|FAIL|SKIP) +$1 " <<< "$2" || true; }
printf '2026-11-25T20:35:27Z static input compiler sha256: %s\n2026-11-25T20:35:28Z building\n' "$dynamic_hash" > log-good
printf '2026-11-25T20:35:27Z static input compiler sha256: %s\n' "$(printf x | sha256sum | cut -d' ' -f1)" > log-other
printf '2026-11-25T20:35:28Z building\n' > log-none
out=$(run log-good); [[ $(line static-input "$out") == PASS* ]] || fail "an equal hash is not a PASS: $(line static-input "$out")"
out=$(run log-other); [[ $(line static-input "$out") == FAIL* ]] || fail "a different hash is not a FAIL: $(line static-input "$out")"
out=$(run log-none); [[ $(line static-input "$out") == SKIP*WARNING* ]] || fail "a log without the line is not a SKIP with a warning: $(line static-input "$out")"
out=$(FAKE_GH_FAIL=1 run log-good); [[ $(line static-input "$out") == SKIP* ]] || fail "an unreadable log is not a SKIP: $(line static-input "$out")"
# Without the dynamic asset there is nothing to compare: no line.
rm artifacts/ablac-dynamic-x86_64-linux artifacts/ablac-dynamic-x86_64-linux.sha256
out=$(run log-good); [[ -z $(line static-input "$out") ]] || fail "a static-input line without a dynamic asset"
echo 'release-check static-input: equal hash passes, different fails, missing line or log skips'

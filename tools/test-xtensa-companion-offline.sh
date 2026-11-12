#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out="$root/build/xtensa-companion-offline"
restore_output_permissions() {
    local status=$?
    if [[ -d $out && ! -L $out ]] && ! chmod -R u+w "$out"; then
        printf 'failed to restore owner write permission under %s\n' "$out" >&2
        if [[ $status -eq 0 ]]; then status=1; fi
    fi
    return "$status"
}
trap restore_output_permissions EXIT
if [[ -d $out ]]; then chmod -R u+w "$out"; rm -rf "$out"; fi
mkdir -p "$out/fixtures" "$out/target" "$out/negative" "$out/fault" "$out/concurrent" "$out/many" "$out/root-link"
python3 tests/cases/xtensa-companion-offline/make-fixtures.py "$out/fixtures"
"$compiler" build tests/cases/xtensa-companion-offline/main.ab -o "$out/test" --fast --no-cache
run() { "$out/test" "$out/fixtures/$1.json" "$2" "$out/fixtures" "$1.tar.gz" "$3" "${4:-new}"; }
ln -s old "$out/target/current"
run good "$out/target" '' new
[[ $(readlink "$out/target/current") == old ]]
# A larger tree must not leak descriptors during extraction or verification.
(ulimit -n 64; run many "$out/many" '' new; run many "$out/many" '' existing)
ln -s nowhere "$out/root-link/23.1.3-1"
run good "$out/root-link" existing_type
[[ $(readlink "$out/root-link/23.1.3-1") == nowhere ]]
run good "$out/target" '' existing
# 0700 denotes an incomplete publication. A verifier and an installer wait
# for a live publisher; a crashed publisher is never silently repaired.
incomplete='publication_in_progress: directory 23.1.3-1; ensure no installer is running, remove this directory, and rerun'
chmod 0700 "$out/target/23.1.3-1"
run good "$out/target" "$incomplete" verify
run good "$out/target" "$incomplete"
(sleep 0.1; chmod 0555 "$out/target/23.1.3-1") & publisher=$!
run good "$out/target" '' verify
wait "$publisher"
chmod 0700 "$out/target/23.1.3-1"
chmod -R u+w "$out/target/23.1.3-1"
rm -rf "$out/target/23.1.3-1"
run good "$out/target" '' new
# An already installed tree is verified without hashing the supplied archive.
run archivehash "$out/target" '' existing
"$out/test" "$out/fixtures/good.json" "$out/target" "$out/fixtures" missing.tar.gz '' existing
[[ $(readlink "$out/target/current") == old ]]
for item in identity:manifest_identity extra:file_set filehash:file_hash rawpath:archive_path mode:file_mode archivehash:archive_hash manifesthash:manifest_hash gzipbad:gzip_invalid tarbad:tar_invalid wrongroot:archive_path; do
    name=${item%:*}; expected=${item#*:}; run "$name" "$out/negative" "$expected"
done
"$out/test" "$out/fixtures/good.json" "$out/negative" "$out/fixtures" oversize.tar.gz archive_limit
[[ -z $(ls -A "$out/negative") ]]
# Same-size, same-mtime modification must not pass existing-tree verification.
python3 - "$out/target/23.1.3-1/bin/opt" <<'PY'
import os,sys
from pathlib import Path
p=Path(sys.argv[1]); info=p.stat(); p.chmod(0o644); p.write_bytes(b'bad'); os.utime(p,ns=(info.st_atime_ns,info.st_mtime_ns)); p.chmod(0o555)
PY
run good "$out/target" existing_file_hash
[[ -z $(find "$out/target" -name '.install-*' -print) ]]
# Refuse links, unexpected files, missing files and a changed manifest in an existing tree.
for case in link extra missing manifest; do
    mkdir -p "$out/$case"
    cp -R "$out/target/23.1.3-1" "$out/$case/23.1.3-1"
    chmod -R u+w "$out/$case/23.1.3-1"
    printf opt > "$out/$case/23.1.3-1/bin/opt"
    chmod 555 "$out/$case/23.1.3-1/bin/opt"
    case $case in
        link) rm "$out/$case/23.1.3-1/bin/opt"; ln -s llc "$out/$case/23.1.3-1/bin/opt"; expected=existing_tree_type ;;
        extra) printf x > "$out/$case/23.1.3-1/extra"; expected=existing_file_set ;;
        missing) rm "$out/$case/23.1.3-1/bin/opt"; expected=existing_file_set ;;
        manifest) printf bad > "$out/$case/23.1.3-1/manifest.json"; expected=existing_manifest_hash ;;
    esac
    chmod 555 "$out/$case/23.1.3-1"
    run good "$out/$case" "$expected"
    [[ -z $(find "$out/$case" -name '.install-*' -print) ]]
done
# Both concurrent publishers succeed; one verifies the winner, neither replaces it.
run good "$out/concurrent" '' either > "$out/concurrent-first.txt" & first=$!
run good "$out/concurrent" '' either > "$out/concurrent-second.txt" & second=$!
wait "$first"; wait "$second"
printf 'existing\nnew\n' > "$out/concurrent-expected.txt"
cat "$out/concurrent-first.txt" "$out/concurrent-second.txt" | LC_ALL=C sort > "$out/concurrent-actual.txt"
cmp "$out/concurrent-expected.txt" "$out/concurrent-actual.txt"
[[ -z $(find "$out/concurrent" -name '.install-*' -print) ]]
# Linux-only syscall fault injection validates rollback at several stages.
if [[ $(uname -s) == Linux ]] && command -v strace >/dev/null; then
    # Invalid manifest data must be rejected before a payload stage exists.
    strace -qq -e trace=mkdirat -o "$out/prevalidate.trace" \
        "$out/test" "$out/fixtures/manifesthash.json" "$out/fault" "$out/fixtures" \
        manifesthash.tar.gz manifest_hash
    if grep -q '\.install-' "$out/prevalidate.trace"; then
        echo 'payload stage created before archive validation' >&2; exit 1
    fi
    [[ -z $(ls -A "$out/fault") ]]
    # Observe actual chmod/rename order on the staging directory. The old
    # order (0555 before rename) fails this check even on permissive Linux.
    mkdir "$out/order"
    strace -qq -yy -e trace=fchmod,renameat2,fsync,write,openat -o "$out/order.trace" \
        "$out/test" "$out/fixtures/good.json" "$out/order" "$out/fixtures" good.tar.gz '' new
    python3 - "$out/order.trace" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
rename = next(i for i, line in enumerate(lines) if line.startswith('renameat2(') and ' = 0' in line)
root_modes = [(i, line) for i, line in enumerate(lines) if re.search(r'fchmod\(\d+<[^>]*(?:/\.install-[^/>]+|/23\.1\.3-1)>, 0?555\)', line)]
assert len(root_modes) == 1 and root_modes[0][0] > rename, (rename, root_modes)
PY
    ordinal=$(python3 - "$out/order.trace" <<'PY'
import re, sys
count = 0
for line in open(sys.argv[1]):
    if line.startswith('fchmod('):
        count += 1
        if re.search(r'fchmod\(\d+<[^>]*/23\.1\.3-1>, 0?555\)', line):
            print(count)
            break
else:
    raise SystemExit('missing final root chmod')
PY
    )
    mkdir "$out/final-mode-fault"
    strace -qq -e "inject=fchmod:error=EIO:when=$ordinal" -o "$out/final-mode.trace" \
        "$out/test" "$out/fixtures/good.json" "$out/final-mode-fault" "$out/fixtures" good.tar.gz "$incomplete" new
    run good "$out/final-mode-fault" "$incomplete" verify
    chmod -R u+w "$out/final-mode-fault/23.1.3-1"
    rm -rf "$out/final-mode-fault/23.1.3-1"
    run good "$out/final-mode-fault" '' new
    for item in write:spool_write fsync:spool_write fchmod:spool_open renameat2:publish; do
        call=${item%:*}; expected=${item#*:}
        strace -qq -e "inject=$call:error=EIO:when=1" -o "$out/$call.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz "$expected"
        [[ -z $(ls -A "$out/fault") ]]
    done
    for call in mkdirat write fsync fchmod renameat2; do
        strace -qq -e "inject=$call:error=ENOSPC:when=1" -o "$out/full-$call.trace" \
            "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz disk_full
        [[ -z $(ls -A "$out/fault") ]]
    done
    for call in write fsync; do
        ordinal=$(python3 - "$out/order.trace" "$call" <<'PY'
import sys
count = 0
for line in open(sys.argv[1]):
    if line.startswith(sys.argv[2] + '('):
        count += 1
        if '/.install-' in line:
            print(count)
            break
else:
    raise SystemExit('missing payload ' + sys.argv[2])
PY
        )
        strace -qq -e "inject=$call:error=EIO:when=$ordinal" -o "$out/stage-$call.trace" \
            "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz stage_write
        [[ -z $(ls -A "$out/fault") ]]
    done
    stage_write=$(python3 - "$out/order.trace" <<'PY'
import sys
count = 0
for line in open(sys.argv[1]):
    if line.startswith('write('):
        count += 1
        if '/.install-' in line:
            print(count); break
else: raise SystemExit('missing stage write')
PY
    )
    strace -qq -e "inject=write:error=ENOSPC:when=$stage_write" -o "$out/full-stage-write.trace" \
        "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz disk_full
    [[ -z $(ls -A "$out/fault") ]]
    strace -qq -e "inject=write:error=EIO:when=$stage_write" -e inject=unlinkat:error=EIO:when=1+ \
        -o "$out/stage-cleanup.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" \
        "$out/fixtures" good.tar.gz cleanup stage-cleanup
    chmod -R u+w "$out/fault"; rm -rf "$out/fault"; mkdir "$out/fault"
    spool_open=$(python3 - "$out/order.trace" <<'PY'
import sys
count = 0
for line in open(sys.argv[1]):
    if line.startswith('openat('):
        count += 1
        if '".spool-' in line:
            print(count); break
else: raise SystemExit('missing spool open')
PY
    )
    strace -qq -e "inject=openat:error=EIO:when=$spool_open" -e inject=unlinkat:error=EIO:when=1 \
        -o "$out/spool-open-cleanup.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" \
        "$out/fixtures" good.tar.gz cleanup spool-open-cleanup
    chmod -R u+w "$out/fault"; rm -rf "$out/fault"; mkdir "$out/fault"
    # If the OS itself refuses rollback, return the leftover stage name rather
    # than claiming cleanup succeeded.
    strace -qq -e inject=write:error=EIO:when=1 -e inject=unlinkat:error=EIO:when=1 \
        -o "$out/cleanup.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz cleanup
    [[ -n $(ls -A "$out/fault") ]]
    chmod -R u+w "$out/fault"; rm -rf "$out/fault"; mkdir "$out/fault"
    # Both the stage and spool removals fail; both names and the original
    # rename error must survive in the result.
    strace -qq -e inject=renameat2:error=EIO:when=1 -e inject=unlinkat:error=EIO:when=1+ \
        -o "$out/both-cleanup.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" \
        "$out/fixtures" good.tar.gz cleanup both-cleanup
    [[ -n $(find "$out/fault" -maxdepth 1 -name '.install-*' -print) ]]
    [[ -n $(find "$out/fault" -maxdepth 1 -name '.spool-*' -print) ]]
    chmod -R u+w "$out/fault"; rm -rf "$out/fault"; mkdir "$out/fault"
    strace -qq -e inject=renameat2:error=EIO:when=1 -e inject=unlinkat:error=EIO:when=1 \
        -o "$out/publish-cleanup.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz cleanup
    [[ -n $(ls -A "$out/fault") ]]
    chmod -R u+w "$out/fault"; rm -rf "$out/fault"; mkdir "$out/fault"
else
    echo 'offline installer: syscall fault injection unavailable; skipped'
fi
# Optional size regression: stored gzip data exceeds the previous 128 MiB cap.
if [[ ${ABLA_TEST_XTENSA_LARGE:-0} == 1 ]]; then
    mkdir "$out/large"
    python3 tests/cases/xtensa-companion-offline/make-large.py "$out/fixtures"
    run large "$out/large" '' new
    echo 'offline installer: compressed input above 128 MiB accepted'
fi
# The cached real release is optional; the suite never downloads it.
if [[ -n ${ABLA_TEST_XTENSA_COMPANION:-} && -f $ABLA_TEST_XTENSA_COMPANION ]]; then
    mkdir -p "$out/real" "$out/real-archive" "$out/python"
    cp "$ABLA_TEST_XTENSA_COMPANION" "$out/real-archive/companion.tar.gz"
    python3 - "$out" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); catalog=json.load(open('tools/xtensa-companions.json')); rel=catalog['releases']['23.1.3-1']; item=rel['platforms']['x86_64-linux']
(p/'real.json').write_text(json.dumps({'version':'23.1.3-1','platform':'x86_64-linux','llvmVersion':rel['llvmVersion'],'sourceCommit':rel['sourceCommit'],'sourceArchiveSha256':rel['sourceArchiveSha256'],'archiveSha256':item['sha256'],'manifestSha256':item['manifestSha256']}))
PY
    "$out/test" "$out/real.json" "$out/real" "$out/real-archive" companion.tar.gz '' new
    python3 - "$out" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0,'tools'); import xtensa_companions as c
p=Path(sys.argv[1]); expected=c._extract_archive(p/'real-archive/companion.tar.gz',p/'python','abla-xtensa-llvm-23.1.3-1-x86_64-linux')
for entry in [*sorted(expected.rglob('*'),reverse=True),expected]:
    if entry.is_dir(): entry.chmod(0o555)
actual=p/'real/23.1.3-1'
def inventory(root):
    out={}
    for entry in [root,*root.rglob('*')]:
        name='.' if entry==root else str(entry.relative_to(root)); mode=entry.stat().st_mode & 0o777
        out[name]=('dir',mode) if entry.is_dir() else ('file',mode,c.file_sha256(entry))
    return out
assert inventory(actual)==inventory(expected), 'native/Python tree mismatch'
print('offline installer: real Linux tree matches Python')
PY
else
    echo 'offline installer: real cached companion absent; parity skipped'
fi
echo 'offline installer: verification, exclusive publication, faults and concurrent install passed'

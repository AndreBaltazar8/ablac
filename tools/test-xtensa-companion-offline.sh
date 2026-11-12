#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out="$root/build/xtensa-companion-offline"
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
    for item in write:stage_write fsync:stage_write fchmod:stage_open renameat2:publish; do
        call=${item%:*}; expected=${item#*:}
        strace -qq -e "inject=$call:error=EIO:when=1" -o "$out/$call.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz "$expected"
        [[ -z $(ls -A "$out/fault") ]]
    done
    # If the OS itself refuses rollback, return the leftover stage name rather
    # than claiming cleanup succeeded.
    strace -qq -e inject=write:error=EIO:when=1 -e inject=unlinkat:error=EIO:when=1 \
        -o "$out/cleanup.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz cleanup
    [[ -n $(ls -A "$out/fault") ]]
    chmod -R u+w "$out/fault"; rm -rf "$out/fault"; mkdir "$out/fault"
    strace -qq -e inject=renameat2:error=EIO:when=1 -e inject=unlinkat:error=EIO:when=1 \
        -o "$out/publish-cleanup.trace" "$out/test" "$out/fixtures/good.json" "$out/fault" "$out/fixtures" good.tar.gz cleanup
    [[ -n $(ls -A "$out/fault") ]]
    chmod -R u+w "$out/fault"; rm -rf "$out/fault"; mkdir "$out/fault"
else
    echo 'offline installer: syscall fault injection unavailable; skipped'
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

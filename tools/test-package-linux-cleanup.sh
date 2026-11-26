#!/usr/bin/env bash
# Exercise the real packager's EXIT trap with copied read-only resource dirs.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${1:-$root/build/ablac.bin}
compiler=$(realpath "$compiler")
cd "$root"
# The packager runs the packaged compiler, which names the generic loader /lib64/ld-linux-x86-64.so.2 (the archive is for any
# glibc Linux). A NixOS host has only a stub there that refuses to start it, so the test runs where that loader works (CI's
# Ubuntu runners) and says it was skipped elsewhere.
if ! /lib64/ld-linux-x86-64.so.2 --version > /dev/null 2>&1; then
    echo 'package-linux-cleanup: skipped: this host cannot start a generic-Linux dynamic executable (/lib64/ld-linux-x86-64.so.2)'
    exit 0
fi
out="$root/build/package-linux-cleanup-test"
restore_test_permissions() {
    local status=$?
    if [[ -d $out && ! -L $out ]] && ! chmod -R u+w "$out"; then
        printf 'failed to restore test output permissions: %s\n' "$out" >&2
        if [[ $status -eq 0 ]]; then status=1; fi
    fi
    return "$status"
}
trap restore_test_permissions EXIT
if [[ -d $out ]]; then chmod -R u+w "$out"; rm -rf -- "$out"; fi
mkdir -p "$out/work" "$out/bin" "$out/resource/include/nested" "$out/fail-bin"
printf 'fixture\n' > "$out/resource/include/nested/header.h"
# The packager requires the compiler-rt builtins inside the resource directory it copies (#806): the real archive, at the
# same place under the fixture as under clang's own resource directory, read-only like the rest.
real_resource=$(clang -print-resource-dir)
real_builtins=$(clang --rtlib=compiler-rt -print-libgcc-file-name)
builtins_path=${real_builtins#"$real_resource"/}
mkdir -p "$out/resource/$(dirname "$builtins_path")"
cp "$real_builtins" "$out/resource/$builtins_path"
find "$out/resource" -type d -exec chmod 0555 {} +
export ABLA_TEST_REAL_CLANG="$(command -v clang)" ABLA_TEST_CLANG_RESOURCE="$out/resource" ABLA_TEST_CLANG_BUILTINS="$out/resource/$builtins_path"
cat > "$out/bin/clang" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == -print-resource-dir ]]; then printf '%s\n' "$ABLA_TEST_CLANG_RESOURCE"; exit 0; fi
if [[ ${1:-} == --rtlib=compiler-rt && ${2:-} == -print-libgcc-file-name ]]; then printf '%s\n' "$ABLA_TEST_CLANG_BUILTINS"; exit 0; fi
exec "$ABLA_TEST_REAL_CLANG" "$@"
SH
chmod 0755 "$out/bin/clang"
export PATH="$out/bin:$PATH" TMPDIR="$out/work"
tools/package-linux-toolchain.sh "$compiler" "$root" "$out/success.tar.gz"
test -f "$out/success.tar.gz"
test -z "$(ls -A "$out/work")"
tar -tzf "$out/success.tar.gz" > "$out/archive.list"
grep -q 'lib/clang/resource/include/nested/header.h' "$out/archive.list" || {
    echo 'resource fixture missing from archive' >&2; exit 1;
}
cat > "$out/fail-bin/tar" <<'SH'
#!/usr/bin/env bash
exit 37
SH
chmod 0755 "$out/fail-bin/tar"
set +e
PATH="$out/fail-bin:$PATH" tools/package-linux-toolchain.sh "$compiler" "$root" "$out/fail.tar.gz"
status=$?
set -e
if [[ $status -ne 37 ]]; then echo "expected injected status 37, got $status" >&2; exit 1; fi
test -z "$(ls -A "$out/work")"
chmod -R u+w "$out/resource"
printf '%s\n' 'package-linux-cleanup: read-only resource removed on success and failure'

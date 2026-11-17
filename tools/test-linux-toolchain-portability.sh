#!/usr/bin/env bash
# The packaged Linux toolchain asks nothing of the machine beyond glibc 2.35 (a 2.34 with RHEL 9's backport also works).
# 1. Every 64-bit ELF file of the unpacked archive names no dynamic loader but /lib64/ld-linux-x86-64.so.2 (never a
#    /nix/store path), carries only $ORIGIN-relative RUNPATH/RPATH entries, needs no glibc symbol version above the
#    floor (2.35: the bundled libgcc_s asks for _dl_find_object@GLIBC_2.35, which upstream 2.34 lacks), and links only
#    libraries the archive bundles, apart from glibc's own (libc, libm, libpthread, libdl, librt, libutil, the loader).
# 2. The compiler runs and builds a program in the oldest systems the README names: Ubuntu 22.04 (glibc 2.35) and
#    AlmaLinux 9 (RHEL 9, glibc 2.34 with the backport). The release runner's own glibc is newer than the floor, so
#    running the archive there proves nothing about it.
#
#   tools/test-linux-toolchain-portability.sh <unpacked toolchain root> [highest glibc version, default 2.35]
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! -x $1/libexec/ablac.bin ]]; then
    printf 'usage: %s <unpacked abla-toolchain-x86_64-linux> [glibc floor]\n' "$0" >&2
    exit 2
fi
root=$(realpath "$1")
floor=${2:-2.35}
failures=0
bad() { printf 'toolchain portability: %s: %s\n' "${1#"$root"/}" "$2" >&2; failures=$((failures + 1)); }
system_library() {
    case $1 in
        libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2 | librt.so.1 | libutil.so.1 | ld-linux-x86-64.so.2) return 0 ;;
    esac
    return 1
}
checked=0
while IFS= read -r -d '' file; do
    [[ $(head -c 4 "$file" | od -An -c | tr -d ' ') == '177ELF' ]] || continue
    # 32-bit objects (the i386 sanitizer runtimes) never run here.
    [[ $(head -c 5 "$file" | od -An -tu1 | awk '{ print $5 }') == 2 ]] || continue
    checked=$((checked + 1))
    interpreter=$(readelf -l "$file" | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p')
    if [[ -n $interpreter && $interpreter != /lib64/ld-linux-x86-64.so.2 ]]; then
        bad "$file" "the dynamic loader is $interpreter, not /lib64/ld-linux-x86-64.so.2"
    fi
    while IFS= read -r path; do
        [[ -z $path || $path == '$ORIGIN'* ]] || bad "$file" "the library search path has $path, which is not relative to the file"
    done < <(readelf -d "$file" | sed -n 's/.*\(RUNPATH\|RPATH\).*\[\(.*\)\]/\2/p' | tr ':' '\n')
    while IFS= read -r version; do
        highest=$(printf '%s\n%s\n' "${version#GLIBC_}" "$floor" | sort -V | tail -1)
        [[ $highest == "$floor" ]] || bad "$file" "needs $version, above the floor GLIBC_$floor"
    done < <(readelf --version-info "$file" | grep -o 'Name: GLIBC_[0-9.]*' | sed 's/Name: //' | sort -u)
    while IFS= read -r library; do
        system_library "$library" && continue
        [[ -e $root/lib/$library || -e $(dirname "$file")/$library ]] || bad "$file" "needs $library, which the archive does not bundle"
    done < <(readelf -d "$file" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
done < <(find "$root" -type f -print0)
[[ $checked -gt 0 ]] || { echo 'toolchain portability: no ELF file found' >&2; exit 1; }
[[ $failures -eq 0 ]] || exit 1
for image in \
    ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f \
    almalinux:9@sha256:02df05719ef287ebd0df0a1eedb9172a00bd70703aed7b25660e426b8e0d6047; do
    docker run --rm --network none -v "$root:/opt/abla:ro" "$image" bash -ceu '
        export PATH=/opt/abla/bin:/usr/bin:/bin
        test "$(ablac --version | cut -d" " -f1)" = ablac
        mkdir -p /tmp/smoke && cd /tmp/smoke
        printf "import \"abla/io\"\nfun main: int {\n    println(\"hello\")\n    0\n}\n" > hello.ab
        ablac build hello.ab -o hello --no-cache
        test "$(./hello)" = hello
    ' || { echo "toolchain portability: the archive does not run in $image" >&2; exit 1; }
done
echo "toolchain portability: passed ($checked ELF files, glibc floor $floor; ran in Ubuntu 22.04 and AlmaLinux 9)"

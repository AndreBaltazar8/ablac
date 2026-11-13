#!/usr/bin/env bash
# The packaged Linux toolchain on a machine with no C development files (#806): in a
# bare ubuntu:24.04 (no gcc, no libc6-dev, no binutils), with PATH holding only the
# archive and the system's shell tools, a program that brings no C library builds and
# runs with the toolchain alone, and one that calls a C function fails with a
# diagnostic naming the missing C development files, not with lld's errors alone.
#
#   tools/test-toolchain-without-c-development.sh <unpacked toolchain root>
set -euo pipefail
if [[ $# -ne 1 || ! -x $1/bin/ablac ]]; then
    printf 'usage: %s <unpacked abla-toolchain-x86_64-linux>\n' "$0" >&2
    exit 2
fi
root=$(realpath "$1")
image=ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5
docker run --rm --network none -v "$root:/opt/abla:ro" "$image" bash -ceu '
    for development in gcc cc ld /usr/lib/x86_64-linux-gnu/crti.o \
        /usr/lib/x86_64-linux-gnu/libc.so; do
        if command -v "$development" >/dev/null 2>&1 || [[ -e $development ]]; then
            echo "the image has C development files: $development" >&2
            exit 1
        fi
    done
    export PATH=/opt/abla/bin:/usr/bin:/bin
    mkdir -p /tmp/smoke && cd /tmp/smoke
    printf "import \"abla/io\"\nfun main: int {\n    println(\"hello\")\n    0\n}\n" > hello.ab
    ablac build hello.ab -o hello --no-cache
    test "$(./hello)" = hello
    printf "extern:\"c\" fun getpid(): int\nfun main: int = if (getpid() > 0) 0 else 1\n" > needs-libc.ab
    if ablac build needs-libc.ab -o needs-libc --no-cache 2> needs-libc.log; then
        echo "a program calling the C library built without C development files" >&2
        exit 1
    fi
    cat needs-libc.log >&2
    grep -F "links the C library because it calls C functions: getpid, and this machine has no C development files" needs-libc.log >/dev/null
    printf "import \"abla/build\"\n@export(\"abla_app_answer\")\nfun answer: int = 42\n" > library.ab
    ablac build library.ab --emit shared-library -o library.so --no-cache
    test -s library.so
    test "$(head -c 4 library.so | od -An -c | tr -d "[:space:]")" = "177ELF"
'
echo 'toolchain without C development files: a libc-free program builds and runs, so does a shared library; one needing libc names what is missing'

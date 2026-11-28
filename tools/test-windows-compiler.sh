#!/usr/bin/env bash
# The compiler itself on Windows, before its LLVM is there (step 2 of docs/design/windows-target.md; the LLVM and lld archives
# for windows-msvc are #1137): src/orc_main.ab cross-built for x86_64-windows names nothing outside the Windows runtime's
# imports but LLVM-C functions; linked against a stub LLVM (each function returns 0) and installed as the package lays it out
# (bin/ablac.exe beside share/abla), it runs under Wine from another directory with no ABLA_SYSROOT:
#   - its export table holds every external definition of its object (exports.def, the --export-dynamic of its JIT);
#   - `--version` prints its version;
#   - `fmt` rewrites a file;
#   - compile-time code captures processes (src/ct_process.ab through the runtime's spawn): its --version, past a limit, a missing one;
#   - `build` finds its standard library beside its own image (/proc/self/exe) and takes a program through parsing, analysis
#     and IR to its first LLVM call, which the stub fails: an LLVM error, not a missing toolchain or a refused system call.
# Without Wine (or lld-link, llvm-mc, llvm-ar) the undefined-symbol check still runs and the rest is skipped with a message.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/windows-compiler
rm -rf "$out"
mkdir -p "$out"
fail() { echo "windows-compiler: $1" >&2; exit 1; }
command -v llvm-nm > /dev/null || { echo "windows-compiler: skipped (llvm-nm is not installed)"; exit 0; }
# The whole compiler, built --fast: what this test checks (its imports, its export list, the stub link and the Wine runs)
# does not need it optimized, and the release build took 195 s here and passed the 600 s limit on a CI runner (run
# 45302674020), where --fast takes about a third of that. The launcher's 240 s for an orc_main build
# (tools/run-limited-compiler.sh) is its time alone, and beside the suite's other jobs it went past that (since the compiler
# collects with background freeing and collection threads, 2ece0285c). This build has its own limit.
ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-600} ABLA_WINDOWS_LINK_KEEP=1 \
    "$compiler" build src/orc_main.ab --target x86_64-windows --fast -o "$out/ablac.exe" > "$out/build.log" 2>&1 || true
[[ -s $out/ablac.exe.o ]] || { tail -20 "$out/build.log" >&2; fail "src/orc_main.ab gave no object for Windows"; }

# What the object needs beyond LLVM is what the runtime imports (runtime/windows/imports), nothing of a C library.
llvm-nm -u "$out/ablac.exe.o" | awk '{ print $NF }' | sort -u > "$out/undefined.txt"
cat runtime/windows/imports/*.txt | grep -vE '^[[:space:]]*(#|$)' | sort -u > "$out/imported.txt"
{ grep -vE '^(LLVM|__ImageBase$)' "$out/undefined.txt" || true; } | comm -23 - "$out/imported.txt" > "$out/unexpected.txt"
[[ ! -s $out/unexpected.txt ]] || fail "the compiler names what Windows does not give it: $(tr '\n' ' ' < "$out/unexpected.txt")"
for tool in lld-link llvm-mc llvm-readobj; do
    command -v "$tool" > /dev/null ||
        { echo "windows-compiler: the compiler names only LLVM beyond the runtime's imports; the stub link and Wine runs are skipped ($tool is not installed)"; exit 0; }
done

# The compiler's own link (which the missing LLVM fails) left its import libraries and its export list (ABLA_WINDOWS_LINK_KEEP):
# every external definition of the object, which the code it JIT-compiles finds through the process symbol generator
# (docs/design/windows-jit.md §2). The stub ablac.exe is linked with them and a stub for every LLVM-C function.
kept="$out/ablac.exe.imports"
[[ -s $kept/exports.def ]] || { tail -5 "$out/build.log" >&2; fail "the compiler's link wrote no exports.def"; }
# (__chkstk and the runtime's abla_windows_write and abla_windows_exit are weak externals, and functions: listed without DATA.)
for symbol in __emutls_get_address main abla_windows_start __chkstk abla_windows_write abla_windows_exit; do
    grep -q "^    $symbol\$" "$kept/exports.def" || fail "exports.def does not export $symbol"
done
# write and _exit stay the C library's: LLVM's raw_fd_ostream writes the CRT's descriptors with them, which the runtime's write
# (over its own descriptor table) would lose, leaving the objects the embedded llc writes empty.
for symbol in write _exit; do
    ! grep -q "^    $symbol\$" "$kept/exports.def" || fail "exports.def exports $symbol: the runtime's definition would take the CRT's place"
done
defined=$(llvm-nm --defined-only --extern-only "$out/ablac.exe.o" | wc -l)
listed=$(grep -c '^    ' "$kept/exports.def")
[[ $listed == "$defined" ]] || fail "exports.def lists $listed symbols, the object defines $defined"
# What the Windows compiler's compile-time slices leave for its process to resolve (docs/design/windows-jit.md): ORC finds a
# symbol in ablac.exe's exports (exports.def above) or in a system DLL the runtime imports from (runtime/windows/imports), and
# nowhere else, so a POSIX name (pthread_self, pthread_kill, pause, write: tier=native run 45280182873) fails the generation
# and every site falls back to the interpreter. The slice a Windows host makes is written here by this compiler
# (ABLA_CT_HOST_TRIPLE: made for that host, dumped, never run) for a scalar site, and every symbol it declares must be one of
# those, or an LLVM intrinsic: in the slice after the passes the JIT runs on it (generation-<g>.optimized.ll), as ORC sees it.
slice="$out/ct-slice"
rm -rf "$slice"
ABLA_CT_HOST_TRIPLE=x86_64-pc-windows-msvc ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_DUMP="$slice" \
    "$compiler" build tests/cases/compile-eval-jit/scalars.ab --target x86_64-windows -o "$out/ct-slice.exe" --no-cache \
    > "$out/ct-slice.log" 2>&1 || { tail -5 "$out/ct-slice.log" >&2; fail "the compile-time slice probe did not build"; }
ls "$slice"/generation-*.optimized.ll > /dev/null 2>&1 || fail "no optimized Windows compile-time slice was written ($out/ct-slice.log)"
{ awk '/^    / { print $1 }' "$kept/exports.def"; grep -hv '^#' runtime/windows/imports/*.txt; } | sort -u > "$out/ct-slice.allowed"
# A declaration nothing in the slice uses gives ORC nothing to resolve (the runtime's declarations are many): only a declared
# symbol the code names again counts.
grep -h '^declare' "$slice"/generation-*.optimized.ll | sed -E 's/.* @"?([^"( ]+)"?\(.*/\1/' | grep -v '^llvm\.' | sort -u |
    while read -r symbol; do
        uses=$(grep -ohE "@\"?${symbol//./\\.}\"?[(, )]" "$slice"/generation-*.optimized.ll | wc -l)
        ((uses > 1)) && echo "$symbol"
    done > "$out/ct-slice.declared" || true
[[ -s $out/ct-slice.declared ]] || fail "the Windows compile-time slice declares nothing to resolve: the probe is not a native slice"
unresolved=$(comm -23 "$out/ct-slice.declared" "$out/ct-slice.allowed")
[[ -z $unresolved ]] || fail "a Windows compile-time slice declares what ablac.exe cannot resolve: $(tr '\n' ' ' <<< "$unresolved")"
{ echo .text; grep '^LLVM' "$out/undefined.txt" | while read -r symbol; do printf '.globl %s\n%s:\n    xorl %%eax, %%eax\n    ret\n' "$symbol" "$symbol"; done; } > "$out/stub.s"
llvm-mc -triple x86_64-pc-windows-msvc -filetype=obj "$out/stub.s" -o "$out/stub.o"
mkdir -p "$out/package/bin" "$out/package/share/abla" "$out/work"
lld-link /nologo /subsystem:console /entry:abla_windows_start /nodefaultlib /machine:x64 /brepro /stack:134217728 \
    "/out:$out/package/bin/ablac.exe" "$out/ablac.exe.o" "$out/stub.o" "$kept"/*.lib "/def:$kept/exports.def" > "$out/link.log" 2>&1 ||
    { cat "$out/link.log" >&2; fail "ablac.exe did not link against the stub LLVM"; }
llvm-readobj --coff-exports "$out/package/bin/ablac.exe" | awk '/Name:/ { print $2 }' > "$out/exports.txt"
grep -qx __emutls_get_address "$out/exports.txt" || fail "ablac.exe does not export __emutls_get_address"
[[ $(wc -l < "$out/exports.txt") -ge $defined ]] || fail "ablac.exe exports $(wc -l < "$out/exports.txt") names, its object defines $defined"
ln -s "$root/stdlib" "$out/package/share/abla/stdlib"
ln -s "$root/runtime" "$out/package/share/abla/runtime"
printf 'import "abla/io"\nfun main {   println("hello")   }\n' > "$out/work/hello.ab"

# run <name> <arguments...>: ablac.exe in work/, no ABLA_SYSROOT; output in $out/<name>.out, status in $status.
run() {
    local name=$1
    shift
    status=0
    (cd "$out/work" && env -u ABLA_SYSROOT -u ABLA_STDLIB "$root/tools/windows/wine-run.sh" ../package/bin/ablac.exe "$@") \
        > "$out/$name.out" 2>&1 || status=$?
    [[ $status != 125 ]] || { echo "windows-compiler: the compiler names only LLVM beyond the runtime's imports and links against a stub LLVM; the Wine runs are skipped (Wine is not installed)"; exit 0; }
    ! grep -q 'unsupported Linux system call' "$out/$name.out" || fail "$name: $(grep 'unsupported Linux system call' "$out/$name.out")"
    return 0
}
run version --version
[[ $status == 0 ]] && grep -q '^ablac [0-9]' "$out/version.out" || fail "--version ($status): $(head -3 "$out/version.out")"
cp "$out/work/hello.ab" "$out/hello.before"
run fmt fmt hello.ab
[[ $status == 0 ]] || fail "fmt exited $status: $(head -3 "$out/fmt.out")"
! cmp -s "$out/hello.before" "$out/work/hello.ab" || fail "fmt left hello.ab as it was"
run build build hello.ab -o hello.exe
grep -q 'E_TOOLCHAIN_ROOT\|no standard library' "$out/build.out" && fail "build found no toolchain: $(head -3 "$out/build.out")"
grep -q 'E_LLVM' "$out/build.out" || fail "build did not reach LLVM ($status): $(head -5 "$out/build.out")"

# Compile-time processes (src/ct_process.ab: the runtime's spawn, no fork), in the evaluator (the JIT needs LLVM) before the
# first LLVM call: the compiler's own --version, its output past a 3-byte limit, and a program that does not exist.
mkdir -p "$out/work/capture"
printf 'compileCapabilities = ["process.io"]\n' > "$out/work/capture/abla.toml"
cat > "$out/work/capture/main.ab" <<'EOF'
import "abla/compiler"
import "abla/text"
import "abla/io"
#compilerGrant("process.io")
compile fun show(label: string, result: CompilerProcessResult): string {
    println("capture $label: failure='${result.failure}' exit=${result.exitCode} read=${result.bytesRead} ${result.stdout.trim()}")
    label
}
compile fun captures(): string {
    show("version", compilerCaptureProcess(["/proc/self/exe", "--version"]))
    show("limit", compilerCaptureProcess(["/proc/self/exe", "--version"], 3, 10000))
    show("missing", compilerCaptureProcess(["Z:/abla-capture-nonexistent.exe"]))
    "done"
}
val DONE = #captures()
fun main { println(DONE) }
EOF
ABLA_COMPILE_EVAL=interp run capture build capture/main.ab -o capture.exe
grep -q "capture version: failure='' exit=0 read=[0-9]* ablac [0-9]" "$out/capture.out" ||
    fail "a compile-time capture of ablac --version: $(grep -m3 'capture\|error' "$out/capture.out")"
grep -q "capture limit: failure='output-limit' exit=-\?[0-9]* read=4 *$" "$out/capture.out" ||
    fail "a capture past its limit: $(grep -m1 'capture limit' "$out/capture.out")"
grep -q "capture missing: failure='launch'" "$out/capture.out" ||
    fail "a capture of a missing program: $(grep -m1 'capture missing' "$out/capture.out")"
echo "windows-compiler: ablac.exe (a stub LLVM) runs --version, fmt, compile-time process captures and build up to its first LLVM call under Wine, its toolchain found beside it"

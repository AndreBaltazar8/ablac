#!/usr/bin/env bash
# Module identity by the host's path syntax (src/module_paths.ab, abla/fs/path, Path in abla/sys/linux/fs):
#   - tests/cases/module-path-identity/main.ab checks bootstrapNormalizeModulePath by the POSIX and the Windows syntax on Linux
#     (drives, UNC shares, `\` read as `/`, the root kept);
#   - host.ab prints what the host's Path gives: POSIX's on Linux; built for x86_64-windows-hosted and run under Wine, Windows's
#     (a drive path is absolute, joins and normal forms come back `/`-separated, a verbatim `\\?\` path as written);
#   - compile-time code may still call Path's lexical methods with no capability (pathHostIsWindows is a provider).
# The Wine half is skipped with a message without Wine or lld-link.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/module-path-identity
rm -rf "$out"
mkdir -p "$out"
fail() { echo "module-path-identity: $1" >&2; exit 1; }
cases=tests/cases/module-path-identity
"$compiler" build "$cases/main.ab" -o "$out/syntax" --fast --no-cache > "$out/syntax.log" 2>&1 || { cat "$out/syntax.log" >&2; fail "main.ab did not build"; }
"$out/syntax" > "$out/syntax.out" || fail "the syntax checks failed: $(cat "$out/syntax.out")"
grep -qx 'syntax ok' "$out/syntax.out" || fail "the syntax checks: $(cat "$out/syntax.out")"

# Compile time: a `#` expression joins and normalizes paths without asking for trusted.native.
cat > "$out/compile-time.ab" <<'EOF'
import "abla/io"
import "abla/sys/linux/fs"
val joined = #Path("a/b").child("c").normalized().text
fun main { println("compile time $joined") }
EOF
"$compiler" build "$out/compile-time.ab" -o "$out/compile-time" --fast --no-cache > "$out/compile-time.log" 2>&1 ||
    { cat "$out/compile-time.log" >&2; fail "a compile-time Path.child needed a capability"; }
[[ $("$out/compile-time") == 'compile time a/b/c' ]] || fail "compile time: $("$out/compile-time")"

"$compiler" build "$cases/host.ab" -o "$out/linux" --fast --no-cache > "$out/linux.log" 2>&1 || { cat "$out/linux.log" >&2; fail "host.ab did not build"; }
"$out/linux" > "$out/linux.out" || fail "the Linux run failed: $(cat "$out/linux.out")"
cat > "$out/linux.expected" <<'EOF'
host windows false
host absolute false true
host child C:\x/y
host normalized C:\a\.\b\..\c
host parent C:/a
host verbatim \\?\C:\a/b
EOF
diff "$out/linux.expected" "$out/linux.out" > /dev/null || fail "Linux: $(diff "$out/linux.expected" "$out/linux.out")"
command -v lld-link > /dev/null || { echo "module-path-identity: both syntaxes, compile time and the Linux host checked; Wine skipped (no lld-link)"; exit 0; }
"$compiler" build "$cases/host.ab" --target x86_64-windows-hosted -o "$out/windows.exe" --fast --no-cache > "$out/windows.log" 2>&1 ||
    { cat "$out/windows.log" >&2; fail "host.ab did not build for Windows"; }
status=0
tools/windows/wine-run.sh "$out/windows.exe" > "$out/windows.out" 2> "$out/windows.err" || status=$?
if [[ $status == 125 ]]; then
    echo "module-path-identity: both syntaxes, compile time and the Linux host checked; Wine skipped (not installed)"
    exit 0
fi
[[ $status == 0 ]] || fail "the Windows run exited $status: $(cat "$out/windows.out" "$out/windows.err")"
cat > "$out/windows.expected" <<'EOF'
host windows true
host absolute true false
host child C:/x/y
host normalized C:/a/c
host parent C:/a
host verbatim \\?\C:\a\b
EOF
tr -d '\r' < "$out/windows.out" > "$out/windows.lf"
diff "$out/windows.expected" "$out/windows.lf" > /dev/null || fail "Windows: $(diff "$out/windows.expected" "$out/windows.lf")"
echo "module-path-identity: module identity and Path follow the POSIX syntax on Linux and the Windows one under Wine; compile-time Path needs no capability"

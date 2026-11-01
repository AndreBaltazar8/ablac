#!/usr/bin/env bash
# The LLVM on PATH can target Xtensa and carries ablac's patches, and the compiler
# makes an Xtensa object with it. Nothing here runs Xtensa.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <ablac>\n' "$0" >&2
    exit 2
fi
compiler=$(realpath "$1")
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf -- "$out"' EXIT

llc --version | grep -q 'xtensa '
hidden_options=$(llc --help-hidden)
for option in xtensa-direct-calls xtensa-narrow-branches xtensa-text-section-literals; do
    grep -q -- "--$option" <<<"$hidden_options"
done

cat > "$out/patches.ll" <<'IR'
target triple = "xtensa-esp-unknown-elf"
declare void @external()
define void @target() { ret void }
define void @direct() {
  call void @target()
  ret void
}
define i32 @mask(i32 %x) {
  %masked = and i32 %x, 255
  ret i32 %masked
}
define i32 @bit(i32 %x, i32 %y) {
  %bit = and i32 %x, 4
  %clear = icmp eq i32 %bit, 0
  br i1 %clear, label %a, label %b
a:
  call void @external()
  ret i32 %y
b:
  ret i32 2
}
define i32 @zero(i32 %x) {
  %clear = icmp eq i32 %x, 0
  br i1 %clear, label %a, label %b
a:
  call void @external()
  ret i32 1
b:
  ret i32 2
}
IR
llc -mcpu=esp32 -relocation-model=static -O2 -xtensa-direct-calls \
    -xtensa-narrow-branches -xtensa-text-section-literals \
    "$out/patches.ll" -o "$out/patches.s"
for instruction in 'call8[[:space:]]+target' 'extui' 'bbsi' 'beqz\.n'; do
    grep -qE "$instruction" "$out/patches.s" || {
        printf 'llc does not emit %s: ablac patches missing\n' "$instruction" >&2
        exit 1
    }
done

mkdir -p "$out/tools"
real_llc=$(command -v llc)
cat > "$out/tools/llc" <<SH
#!/usr/bin/env bash
arguments=()
for argument in "\$@"; do
    [[ \$argument == -relocation-model=pic ]] && argument=-relocation-model=static
    arguments+=("\$argument")
done
exec "$real_llc" -mcpu=esp32 "\${arguments[@]}"
SH
chmod +x "$out/tools/llc"
PATH="$out/tools:$PATH" "$compiler" build \
    "$project_root/tests/cases/f32/xtensa.ab" -o "$out/fixture.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object
llvm-readobj --file-headers "$out/fixture.o" | grep -q 'Machine: EM_XTENSA'

echo 'Xtensa LLVM passed'

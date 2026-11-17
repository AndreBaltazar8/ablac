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

llc --version | grep 'xtensa ' >/dev/null
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

# A frame of 128 to 255 bytes that takes a stack address needs the scavenger's emergency slot (LEA_ADD's ADDI reaches 127):
# without it llc aborts ("Cannot scavenge register without an emergency spill slot!").
llc -mcpu=esp32 -relocation-model=static -O2 -xtensa-direct-calls -xtensa-narrow-branches \
    "$project_root/tests/cases/xtensa-llc/scavenging-slot.ll" -o "$out/scavenging-slot.s" 2> "$out/scavenging-slot.log" || {
    cat "$out/scavenging-slot.log" >&2
    printf 'llc aborts on a 128 to 255 byte frame that takes a stack address: nix/llvm-xtensa-scavenging-slot.patch is missing or too narrow\n' >&2
    exit 1
}

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
llvm-readobj --file-headers "$out/fixture.o" | grep 'Machine: EM_XTENSA' >/dev/null

# The intrinsics whose inline assembly the compiler writes: LLVM's Xtensa backend
# takes `r` for an address register and rejects `a`.
cat > "$out/intrinsics.ab" <<'AB'
import "abla/unsafe/xtensa"
@export("intrinsics_probe")
trusted fun probe(mask: u32): u32 {
    nativeXtensaDelayCycles(8)
    nativeXtensaInterruptsEnable(mask) | nativeXtensaInterruptsDisable(mask)
}
AB
PATH="$out/tools:$PATH" "$compiler" build "$out/intrinsics.ab" -o "$out/intrinsics.o" \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object --no-cache
grep -Fq '"r,~{a8},~{a9}"' "$out/intrinsics.o.ll"
llc -mcpu=esp32 -relocation-model=static -O2 "$out/intrinsics.o.ll" -o "$out/intrinsics.s" 2>"$out/intrinsics.err"
if grep -q 'unknown asm constraint' "$out/intrinsics.err"; then
    cat "$out/intrinsics.err" >&2
    exit 1
fi
echo 'Xtensa LLVM passed'

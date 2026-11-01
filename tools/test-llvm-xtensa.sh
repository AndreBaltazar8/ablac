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

# A frame of 128 to 255 bytes that takes a stack address, under register pressure:
# LEA_ADD's ADDI reaches 127 bytes, so a scratch register may need the scavenger's
# slot (reduced from a function of abla-embedded's imu-offsets).
cat > "$out/scavenging.ll" <<'IR'
target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
target triple = "xtensa-esp-unknown-elf"

define fastcc i32 @abla_fn_670449120_736179281_direct(i1 %scalar.compare.not, ptr %unsafe.stack.allocation430, i32 %unsafe.load.i, ptr %unsafe.stack.allocation383.i, i32 %0, i32 %scalar.add.i445, i8 %unsafe.load255.i, i5 %scalar.local67.0.i) {
entry:
  %unsafe.stack.allocation383.i1 = alloca [112 x i8], align 16
  br i1 %scalar.compare.not, label %source.label75, label %common.ret

common.ret:                                       ; preds = %abla_fn_392033005_197864730_direct.exit.thread, %entry
  ret i32 0

source.label75:                                   ; preds = %entry
  %unsafe.stack.allocation4303 = alloca [48 x i8], align 16
  br label %source.label68.i.outer756

source.label68.i.outer756:                        ; preds = %source.label72.i, %source.label75
  br label %source.label68.i

source.label68.i:                                 ; preds = %source.label69.i, %source.label68.i.outer756
  switch i5 %scalar.local67.0.i, label %source.label69.i [
    i5 -14, label %abla_fn_392033005_197864730_direct.exit.thread
    i5 -13, label %abla_fn_392033005_197864730_direct.exit.thread
    i5 14, label %source.label107.i
    i5 -15, label %abla_fn_392033005_197864730_direct.exit.thread
  ]

source.label69.i:                                 ; preds = %source.label68.i
  br i1 %scalar.compare.not, label %source.label72.i, label %source.label68.i

source.label72.i:                                 ; preds = %source.label69.i
  store i32 %unsafe.load.i, ptr %unsafe.stack.allocation383.i, align 8
  store i32 255, ptr null, align 4
  store i32 0, ptr %unsafe.stack.allocation430, align 16
  %direct.scalar389.i = call fastcc i32 null(i32 %scalar.add.i445, i32 0, i32 0, i32 0, i32 %0, i32 0, i32 1, i32 0, i32 0)
  br label %source.label68.i.outer756

source.label107.i:                                ; preds = %source.label68.i
  ret i32 0

abla_fn_392033005_197864730_direct.exit.thread:   ; preds = %source.label68.i, %source.label68.i, %source.label68.i
  switch i8 %unsafe.load255.i, label %common.ret [
    i8 -128, label %source.label155
    i8 0, label %source.label155
  ]

source.label155:                                  ; preds = %abla_fn_392033005_197864730_direct.exit.thread, %abla_fn_392033005_197864730_direct.exit.thread
  ret i32 0
}
IR
llc -mcpu=esp32 -relocation-model=static -O2 "$out/scavenging.ll" -o "$out/scavenging.s"

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

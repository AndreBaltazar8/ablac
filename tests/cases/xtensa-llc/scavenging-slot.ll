; Xtensa llc used to abort on this: "Cannot scavenge register without an emergency spill slot!" (spilling A6). The frame
; is 128 to 255 bytes and takes a stack address, so LEA_ADD's ADDI (-128..127) needs a scratch register, and the scavenger
; had no slot: nix/llvm-xtensa-scavenging-slot.patch reserved one only past 255 bytes. Reduced (llvm-reduce) from
; abla-embedded's imu-offsets (abla_fn_670449120_736179281_direct); tools/test-llvm-xtensa.sh compiles it.
target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
target triple = "xtensa-esp-unknown-elf"

define fastcc i32 @abla_fn_670449120_736179281_direct(i1 %scalar.compare.not, ptr %unsafe.stack.allocation91, i32 %unsafe.load.i, ptr %unsafe.stack.allocation139.i, i32 %0, i32 %scalar.add.i108, i8 %unsafe.load206.i, i5 %scalar.local32.0.i) {
entry:
  %unsafe.stack.allocation139.i1 = alloca [112 x i8], align 16
  br i1 %scalar.compare.not, label %source.label4, label %common.ret

common.ret:                                       ; preds = %abla_fn_392033005_197864730_direct.exit.thread, %entry
  ret i32 0

source.label4:                                    ; preds = %entry
  %unsafe.stack.allocation913 = alloca [48 x i8], align 16
  br label %source.label33.i.outer419

source.label33.i.outer419:                        ; preds = %source.label36.i, %source.label4
  br label %source.label33.i

source.label33.i:                                 ; preds = %source.label34.i, %source.label33.i.outer419
  switch i5 %scalar.local32.0.i, label %source.label34.i [
    i5 -14, label %abla_fn_392033005_197864730_direct.exit.thread
    i5 -13, label %abla_fn_392033005_197864730_direct.exit.thread
    i5 14, label %source.label62.i
    i5 -15, label %abla_fn_392033005_197864730_direct.exit.thread
  ]

source.label34.i:                                 ; preds = %source.label33.i
  br i1 %scalar.compare.not, label %source.label36.i, label %source.label33.i

source.label36.i:                                 ; preds = %source.label34.i
  store i32 %unsafe.load.i, ptr %unsafe.stack.allocation139.i, align 8
  store i32 255, ptr null, align 4
  store i32 0, ptr %unsafe.stack.allocation91, align 16
  %direct.scalar340.i = call fastcc i32 null(i32 %scalar.add.i108, i32 0, i32 0, i32 0, i32 %0, i32 0, i32 1, i32 0, i32 0)
  br label %source.label33.i.outer419

source.label62.i:                                 ; preds = %source.label33.i
  ret i32 0

abla_fn_392033005_197864730_direct.exit.thread:   ; preds = %source.label33.i, %source.label33.i, %source.label33.i
  switch i8 %unsafe.load206.i, label %common.ret [
    i8 -128, label %source.label72
    i8 0, label %source.label72
  ]

source.label72:                                   ; preds = %abla_fn_392033005_197864730_direct.exit.thread, %abla_fn_392033005_197864730_direct.exit.thread
  ret i32 0
}

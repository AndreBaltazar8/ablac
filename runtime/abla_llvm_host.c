#include <stdint.h>

#include <llvm-c/Target.h>

/* LLVM's native-target helpers are static inline C functions. Keep that
 * compile-time architecture selection behind this compiler-only adapter
 * instead of mirroring LLVM's target list in Abla source. */
int32_t ablaLlvmInitializeNativeTarget(void) {
    if (LLVMInitializeNativeTarget() != 0) return 1;
    if (LLVMInitializeNativeAsmPrinter() != 0) return 2;
    if (LLVMInitializeNativeAsmParser() != 0) return 3;
    return 0;
}

#!/usr/bin/env bash
# Writes LLVM IR (stdout) that makes the optimiser and the code generator introduce libcalls: every <math.h> intrinsic in double and float,
# the libm functions called by name (so the library-call simplifier rewrites them: pow(x, 0.5) to sqrt, pow(2, x) to exp2, ...), the
# memory and string functions, loops the idiom pass turns into memset/memcpy, an frem, wide integer division, float to and from i128.
# tools/test-libcall-coverage.sh compiles it for x86-64 and AArch64 and checks every undefined symbol is one the static compiler's JIT knows.
set -euo pipefail
echo
one=(sqrt sin cos tan exp exp2 exp10 log log2 log10 fabs floor ceil trunc rint nearbyint round roundeven asin acos atan sinh cosh tanh)
for t in double float; do
    s=f64; [[ $t == float ]] && s=f32
    for f in "${one[@]}"; do
        # fabs and the roundings are LLVM intrinsics; sin and the like are too (llvm.sin etc. since LLVM 18); asin and friends since 19.
        echo "declare $t @llvm.$f.$s($t)"
        echo "define $t @intrinsic_${f}_$s($t %a) {"
        echo "  %r = call $t @llvm.$f.$s($t %a)"
        echo "  ret $t %r"
        echo "}"
    done
    for f in pow copysign minnum maxnum minimum maximum atan2; do
        echo "declare $t @llvm.$f.$s($t, $t)"
        echo "define $t @intrinsic_${f}_$s($t %a, $t %b) {"
        echo "  %r = call $t @llvm.$f.$s($t %a, $t %b)"
        echo "  ret $t %r"
        echo "}"
    done
    for f in fma fmuladd; do
        echo "declare $t @llvm.$f.$s($t, $t, $t)"
        echo "define $t @intrinsic_${f}_$s($t %a, $t %b, $t %c) {"
        echo "  %r = call $t @llvm.$f.$s($t %a, $t %b, $t %c)"
        echo "  ret $t %r"
        echo "}"
    done
    echo "declare $t @llvm.powi.$s.i32($t, i32)"
    echo "define $t @intrinsic_powi_$s($t %a, i32 %n) {"
    echo "  %r = call $t @llvm.powi.$s.i32($t %a, i32 %n)"
    echo "  ret $t %r"
    echo "}"
    echo "declare $t @llvm.ldexp.$s.i32($t, i32)"
    echo "define $t @intrinsic_ldexp_$s($t %a, i32 %n) {"
    echo "  %r = call $t @llvm.ldexp.$s.i32($t %a, i32 %n)"
    echo "  ret $t %r"
    echo "}"
    echo "declare { $t, i32 } @llvm.frexp.$s.i32($t)"
    echo "define { $t, i32 } @intrinsic_frexp_$s($t %a) {"
    echo "  %r = call { $t, i32 } @llvm.frexp.$s.i32($t %a)"
    echo "  ret { $t, i32 } %r"
    echo "}"
    for f in lround llround lrint llrint; do
        echo "declare i64 @llvm.$f.i64.$s($t)"
        echo "define i64 @intrinsic_${f}_$s($t %a) {"
        echo "  %r = call i64 @llvm.$f.i64.$s($t %a)"
        echo "  ret i64 %r"
        echo "}"
    done
    echo "define $t @frem_$s($t %a, $t %b) {"
    echo "  %r = frem $t %a, %b"
    echo "  ret $t %r"
    echo "}"
done
echo
# the libm functions by name, in double (name) and float (name + f)
for f in sqrt cbrt exp exp2 exp10 expm1 log log2 log10 log1p logb sin cos tan asin acos atan sinh cosh tanh asinh acosh atanh erf erfc fabs floor ceil trunc rint nearbyint round; do
    echo "declare double @$f(double)"
    echo "declare float @${f}f(float)"
    echo "define double @call_$f(double %a) {"
    echo "  %r = call double @$f(double %a)"
    echo "  ret double %r"
    echo "}"
    echo "define float @call_${f}f(float %a) {"
    echo "  %r = call float @${f}f(float %a)"
    echo "  ret float %r"
    echo "}"
done
for f in pow fmod atan2 hypot fmin fmax copysign remainder fdim; do
    echo "declare double @$f(double, double)"
    echo "declare float @${f}f(float, float)"
    echo "define double @call_$f(double %a, double %b) {"
    echo "  %r = call double @$f(double %a, double %b)"
    echo "  ret double %r"
    echo "}"
    echo "define float @call_${f}f(float %a, float %b) {"
    echo "  %r = call float @${f}f(float %a, float %b)"
    echo "  ret float %r"
    echo "}"
done
cat <<'IR'

; the library-call simplifier's rewrites: pow with a constant exponent, a power of two or ten, exp(log x), sqrt of a square, ...
declare double @ldexp(double, i32)
declare double @frexp(double, ptr)
declare double @modf(double, ptr)
declare void @sincos(double, ptr, ptr)
declare i64 @lround(double)
declare i64 @lrint(double)
define double @rewrite_pow_half(double %a) { %r = call double @pow(double %a, double 5.000000e-01)  ret double %r }
define double @rewrite_pow_two_x(double %a) { %r = call double @pow(double 2.000000e+00, double %a)  ret double %r }
define double @rewrite_pow_ten_x(double %a) { %r = call double @pow(double 1.000000e+01, double %a)  ret double %r }
define double @rewrite_pow_third(double %a) { %r = call double @pow(double %a, double 0x3FD5555555555555)  ret double %r }
define double @rewrite_pow_neg_half(double %a) { %r = call double @pow(double %a, double -5.000000e-01)  ret double %r }
define float @rewrite_powf_two_x(float %a) { %r = call float @powf(float 2.000000e+00, float %a)  ret float %r }
define double @rewrite_pow_int(double %a, i32 %n) { %f = sitofp i32 %n to double  %r = call double @pow(double %a, double %f)  ret double %r }
define double @rewrite_exp_of_log(double %a) { %l = call double @log(double %a)  %r = call double @exp(double %l)  ret double %r }
define double @rewrite_exp2_of_int(i32 %n) { %f = sitofp i32 %n to double  %r = call double @exp2(double %f)  ret double %r }
define double @rewrite_ldexp(double %a, i32 %n) { %r = call double @ldexp(double %a, i32 %n)  ret double %r }
define double @rewrite_sin_cos(double %a) { %s = call double @sin(double %a)  %c = call double @cos(double %a)  %r = fadd double %s, %c  ret double %r }
define float @rewrite_sinf_cosf(float %a) { %s = call float @sinf(float %a)  %c = call float @cosf(float %a)  %r = fadd float %s, %c  ret float %r }
define double @rewrite_sqrt_mul(double %a) { %m = fmul double %a, %a  %r = call double @sqrt(double %m)  ret double %r }
define double @rewrite_cbrt_cube(double %a) { %m = fmul double %a, %a  %c = fmul double %m, %a  %r = call double @cbrt(double %c)  ret double %r }
define i64 @rewrite_lround(double %a) { %r = call i64 @lround(double %a)  ret i64 %r }
define i64 @rewrite_lrint(double %a) { %r = call i64 @lrint(double %a)  ret i64 %r }
define double @rewrite_frexp(double %a, ptr %e) { %r = call double @frexp(double %a, ptr %e)  ret double %r }
define double @rewrite_modf(double %a, ptr %p) { %r = call double @modf(double %a, ptr %p)  ret double %r }
define void @rewrite_sincos(double %a, ptr %s, ptr %c) { %x = call double @sin(double %a)  %y = call double @cos(double %a)  store double %x, ptr %s  store double %y, ptr %c  ret void }

; the memory and string functions, called and made by the idiom passes
declare ptr @memcpy(ptr, ptr, i64)
declare ptr @memmove(ptr, ptr, i64)
declare ptr @memset(ptr, i32, i64)
declare i32 @memcmp(ptr, ptr, i64)
declare i32 @bcmp(ptr, ptr, i64)
declare ptr @memchr(ptr, i32, i64)
declare i64 @strlen(ptr)
declare i64 @strnlen(ptr, i64)
declare i32 @strcmp(ptr, ptr)
declare i32 @strncmp(ptr, ptr, i64)
declare ptr @strchr(ptr, i32)
declare ptr @strrchr(ptr, i32)
declare ptr @strcpy(ptr, ptr)
declare ptr @stpcpy(ptr, ptr)
declare ptr @strncpy(ptr, ptr, i64)
declare ptr @strcat(ptr, ptr)
declare ptr @strstr(ptr, ptr)
declare i64 @strspn(ptr, ptr)
declare i64 @strcspn(ptr, ptr)
declare ptr @strpbrk(ptr, ptr)
declare i32 @strcasecmp(ptr, ptr)
declare i32 @isdigit(i32)
declare i32 @toupper(i32)
declare i32 @abs(i32)
declare i64 @labs(i64)
declare i32 @atoi(ptr)
declare i64 @strtol(ptr, ptr, i32)
declare double @strtod(ptr, ptr)
declare float @strtof(ptr, ptr)
declare ptr @malloc(i64)
declare ptr @calloc(i64, i64)
declare ptr @realloc(ptr, i64)
declare void @free(ptr)
declare i32 @puts(ptr)
declare i32 @putchar(i32)
declare i64 @fwrite(ptr, i64, i64, ptr)
define i64 @call_strlen(ptr %a) { %r = call i64 @strlen(ptr %a)  ret i64 %r }
define i32 @call_strcmp(ptr %a, ptr %b) { %r = call i32 @strcmp(ptr %a, ptr %b)  ret i32 %r }
define i32 @call_memcmp(ptr %a, ptr %b, i64 %n) { %r = call i32 @memcmp(ptr %a, ptr %b, i64 %n)  %c = icmp eq i32 %r, 0  %z = zext i1 %c to i32  ret i32 %z }
define ptr @call_strcpy_literal(ptr %d) { %r = call ptr @strcpy(ptr %d, ptr @hello)  ret ptr %r }
define ptr @call_strcat_literal(ptr %d) { %r = call ptr @strcat(ptr %d, ptr @hello)  ret ptr %r }
define i32 @call_strncmp_literal(ptr %d) { %r = call i32 @strncmp(ptr %d, ptr @hello, i64 3)  ret i32 %r }
define ptr @call_strchr_literal(i32 %c) { %r = call ptr @strchr(ptr @hello, i32 %c)  ret ptr %r }
define i64 @call_strspn_literal(ptr %d) { %r = call i64 @strspn(ptr %d, ptr @hello)  ret i64 %r }
define ptr @call_strstr_literal(ptr %d) { %r = call ptr @strstr(ptr %d, ptr @hello)  ret ptr %r }
define i32 @call_puts_pattern() { %r = call i32 @puts(ptr @hello)  ret i32 %r }
define void @loop_memset(ptr %p, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %q = getelementptr i8, ptr %p, i64 %i
  store i8 0, ptr %q
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
define void @loop_memcpy(ptr %d, ptr %s, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %a = getelementptr i8, ptr %s, i64 %i
  %b = getelementptr i8, ptr %d, i64 %i
  %v = load i8, ptr %a
  store i8 %v, ptr %b
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
define void @loop_memset_pattern(ptr %p, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %q = getelementptr i64, ptr %p, i64 %i
  store i64 -6148914691236517206, ptr %q
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret void
}
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr, ptr, i64, i1)
define void @intrinsic_memcpy(ptr %d, ptr %s, i64 %n) { call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr %s, i64 %n, i1 false)  ret void }
define void @intrinsic_memmove(ptr %d, ptr %s, i64 %n) { call void @llvm.memmove.p0.p0.i64(ptr %d, ptr %s, i64 %n, i1 false)  ret void }
define void @intrinsic_memset(ptr %d, i8 %v, i64 %n) { call void @llvm.memset.p0.i64(ptr %d, i8 %v, i64 %n, i1 false)  ret void }
define void @intrinsic_memcpy_big(ptr %d, ptr %s) { call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr %s, i64 4096, i1 false)  ret void }
@hello = private constant [6 x i8] c"hello\00"

; wide integers: division and remainder, conversions with floats, multiplication with overflow, shifts of i128
define i128 @wide_sdiv(i128 %a, i128 %b) { %r = sdiv i128 %a, %b  ret i128 %r }
define i128 @wide_udiv(i128 %a, i128 %b) { %r = udiv i128 %a, %b  ret i128 %r }
define i128 @wide_srem(i128 %a, i128 %b) { %r = srem i128 %a, %b  ret i128 %r }
define i128 @wide_urem(i128 %a, i128 %b) { %r = urem i128 %a, %b  ret i128 %r }
define i128 @wide_mul(i128 %a, i128 %b) { %r = mul i128 %a, %b  ret i128 %r }
define { i128, i1 } @wide_smulo(i128 %a, i128 %b) { %r = call { i128, i1 } @llvm.smul.with.overflow.i128(i128 %a, i128 %b)  ret { i128, i1 } %r }
declare { i128, i1 } @llvm.smul.with.overflow.i128(i128, i128)
define { i64, i1 } @narrow_smulo(i64 %a, i64 %b) { %r = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 %a, i64 %b)  ret { i64, i1 } %r }
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64)
define i128 @wide_shl(i128 %a, i128 %b) { %r = shl i128 %a, %b  ret i128 %r }
define i128 @wide_lshr(i128 %a, i128 %b) { %r = lshr i128 %a, %b  ret i128 %r }
define i128 @wide_ashr(i128 %a, i128 %b) { %r = ashr i128 %a, %b  ret i128 %r }
define i128 @fptosi128(double %a) { %r = fptosi double %a to i128  ret i128 %r }
define i128 @fptoui128(double %a) { %r = fptoui double %a to i128  ret i128 %r }
define double @sitofp128(i128 %a) { %r = sitofp i128 %a to double  ret double %r }
define double @uitofp128(i128 %a) { %r = uitofp i128 %a to double  ret double %r }
define float @sitofp128f(i128 %a) { %r = sitofp i128 %a to float  ret float %r }
define i128 @fptosi128f(float %a) { %r = fptosi float %a to i128  ret i128 %r }
define i256 @wide256_mul(i256 %a, i256 %b) { %r = mul i256 %a, %b  ret i256 %r }
define i256 @wide256_udiv(i256 %a, i256 %b) { %r = udiv i256 %a, %b  ret i256 %r }
define i32 @popcount(i64 %a) { %r = call i64 @llvm.ctpop.i64(i64 %a)  %t = trunc i64 %r to i32  ret i32 %t }
declare i64 @llvm.ctpop.i64(i64)
define i32 @popcount128(i128 %a) { %r = call i128 @llvm.ctpop.i128(i128 %a)  %t = trunc i128 %r to i32  ret i32 %t }
declare i128 @llvm.ctpop.i128(i128)
define i16 @bswap16(i16 %a) { %r = call i16 @llvm.bswap.i16(i16 %a)  ret i16 %r }
declare i16 @llvm.bswap.i16(i16)
define half @trunc_half(float %a) { %r = fptrunc float %a to half  ret half %r }
define float @ext_half(half %a) { %r = fpext half %a to float  ret float %r }
define half @trunc_half_d(double %a) { %r = fptrunc double %a to half  ret half %r }
IR

; LLVM 23.1.3's InstCombine folds this to copysign(0.0, %v): 0.0 * %v is a zero, so 0.0 / (0.0 * %v) is
; 0.0 / 0.0 = NaN for every %v. Fixed upstream after 23.1.3 (llvm-project #202482, commit bcb4e7d061ac); our
; LLVM carries it as nix/llvm-instcombine-fdiv-zero.patch. tools/test-llvm-miscompiles.sh runs this.
define double @f(i64 %n) {
  %v = sitofp i64 %n to double
  %m = fmul double 0.000000e+00, %v
  %d = fdiv double 0.000000e+00, %m
  %r = fmul double %d, 1.600000e-01
  ret double %r
}

; The backend-neutral kernel bodies: what the Abla kernel lowering emits once per kernel, with buffers as plain pointers
; and the thread index as an argument. Each backend adds only an entry shim (nvptx.ll, cpu.ll, spirv) around them.

; vadd: c[i] = a[i] + b[i] for i < n.
define linkonce_odr void @vadd.body(ptr %a, ptr %b, ptr %c, i32 %n, i32 %i) alwaysinline {
entry:
  %in = icmp ult i32 %i, %n
  br i1 %in, label %run, label %done
run:
  %pa = getelementptr inbounds float, ptr %a, i32 %i
  %pb = getelementptr inbounds float, ptr %b, i32 %i
  %pc = getelementptr inbounds float, ptr %c, i32 %i
  %x = load float, ptr %pa, align 4
  %y = load float, ptr %pb, align 4
  %s = fadd float %x, %y
  store float %s, ptr %pc, align 4
  br label %done
done:
  ret void
}

; E2M1 (NVFP4 element): sign, 2 exponent bits, 1 mantissa bit: 0, 0.5, 1, 1.5, 2, 3, 4, 6.
define linkonce_odr float @e2m1(i32 %n) alwaysinline {
  %e = lshr i32 %n, 1
  %e3 = and i32 %e, 3
  %m = and i32 %n, 1
  %mf = uitofp i32 %m to float
  %sub = fmul float %mf, 5.000000e-01
  %one = fadd float %mf, 2.000000e+00          ; (2 + m) * 2^(e-2) = (1 + m/2) * 2^(e-1)
  %eb = add i32 %e3, 125                       ; 2^(e-2) as float bits
  %bits = shl i32 %eb, 23
  %p = bitcast i32 %bits to float
  %norm = fmul float %one, %p
  %isSub = icmp eq i32 %e3, 0
  %mag = select i1 %isSub, float %sub, float %norm
  %neg = and i32 %n, 8
  %isNeg = icmp ne i32 %neg, 0
  %negmag = fneg float %mag
  %r = select i1 %isNeg, float %negmag, float %mag
  ret float %r
}

; E4M3 (the NVFP4 block scale, unsigned in practice): 4 exponent bits (bias 7), 3 mantissa bits.
define linkonce_odr float @e4m3(i32 %b) alwaysinline {
  %e0 = lshr i32 %b, 3
  %e = and i32 %e0, 15
  %m = and i32 %b, 7
  %mf = uitofp i32 %m to float
  %sub = fmul float %mf, 0x3F60000000000000    ; m * 2^-9
  %m8 = add i32 %m, 8
  %m8f = uitofp i32 %m8 to float
  %eb = add i32 %e, 117                        ; 2^(e-10)
  %bits = shl i32 %eb, 23
  %p = bitcast i32 %bits to float
  %norm = fmul float %m8f, %p
  %isSub = icmp eq i32 %e, 0
  %r = select i1 %isSub, float %sub, float %norm
  ret float %r
}

; nvfp4 row dot: out[row] = g * sum over blocks b of scale(b) * sum_j e2m1(w[row, b*16 + j]) * x[b*16 + j].
; w: rows x k/2 bytes (two elements per byte, low nibble first); s: rows x k/16 E4M3 scales; x: k floats.
define linkonce_odr void @nvfp4dot.body(ptr %w, ptr %s, ptr %x, ptr %out, i32 %rows, i32 %k, float %g, i32 %row) alwaysinline {
entry:
  %in = icmp ult i32 %row, %rows
  br i1 %in, label %start, label %done
start:
  %blocks = lshr i32 %k, 4
  %rowbytes = lshr i32 %k, 1
  %wrow = mul i32 %row, %rowbytes
  %srow = mul i32 %row, %blocks
  br label %block
block:
  %b = phi i32 [ 0, %start ], [ %b1, %blockend ]
  %acc = phi float [ 0.0, %start ], [ %acc1, %blockend ]
  %sidx = add i32 %srow, %b
  %ps = getelementptr inbounds i8, ptr %s, i32 %sidx
  %sb = load i8, ptr %ps
  %sbi = zext i8 %sb to i32
  %scale = call float @e4m3(i32 %sbi)
  %wbase = shl i32 %b, 3
  %wb = add i32 %wrow, %wbase
  %xbase = shl i32 %b, 4
  br label %pair
pair:
  %j = phi i32 [ 0, %block ], [ %j1, %pair ]
  %bs = phi float [ 0.0, %block ], [ %bs2, %pair ]
  %widx = add i32 %wb, %j
  %pw = getelementptr inbounds i8, ptr %w, i32 %widx
  %byte = load i8, ptr %pw
  %bi = zext i8 %byte to i32
  %lo = and i32 %bi, 15
  %hi = lshr i32 %bi, 4
  %vlo = call float @e2m1(i32 %lo)
  %vhi = call float @e2m1(i32 %hi)
  %j2 = shl i32 %j, 1
  %xi = add i32 %xbase, %j2
  %px0 = getelementptr inbounds float, ptr %x, i32 %xi
  %x0 = load float, ptr %px0, align 4
  %px1 = getelementptr inbounds float, ptr %px0, i32 1
  %x1 = load float, ptr %px1, align 4
  %t0 = call float @llvm.fma.f32(float %vlo, float %x0, float %bs)
  %bs2 = call float @llvm.fma.f32(float %vhi, float %x1, float %t0)
  %j1 = add i32 %j, 1
  %pdone = icmp eq i32 %j1, 8
  br i1 %pdone, label %blockend, label %pair
blockend:
  %acc1 = call float @llvm.fma.f32(float %scale, float %bs2, float %acc)
  %b1 = add i32 %b, 1
  %bdone = icmp eq i32 %b1, %blocks
  br i1 %bdone, label %finish, label %block
finish:
  %r = fmul float %acc1, %g
  %po = getelementptr inbounds float, ptr %out, i32 %row
  store float %r, ptr %po, align 4
  br label %done
done:
  ret void
}

declare float @llvm.fma.f32(float, float, float)

; nvfp4 row dot, one subgroup per row: lane l takes blocks l, l + size, ...; the subgroup sum (@kernel_subgroup_sum, one per
; backend) adds the partial sums, and lane 0 stores.
define linkonce_odr void @nvfp4dotSub.body(ptr %w, ptr %s, ptr %x, ptr %out, i32 %rows, i32 %k, float %g, i32 %row, i32 %lane, i32 %size) alwaysinline {
entry:
  %in = icmp ult i32 %row, %rows
  br i1 %in, label %start, label %done
start:
  %blocks = lshr i32 %k, 4
  %rowbytes = lshr i32 %k, 1
  %wrow = mul i32 %row, %rowbytes
  %srow = mul i32 %row, %blocks
  %any = icmp ult i32 %lane, %blocks
  br i1 %any, label %block, label %reduce
block:
  %b = phi i32 [ %lane, %start ], [ %b1, %blockend ]
  %acc = phi float [ 0.0, %start ], [ %acc1, %blockend ]
  %sidx = add i32 %srow, %b
  %ps = getelementptr inbounds i8, ptr %s, i32 %sidx
  %sb = load i8, ptr %ps
  %sbi = zext i8 %sb to i32
  %scale = call float @e4m3(i32 %sbi)
  %wbase = shl i32 %b, 3
  %wb = add i32 %wrow, %wbase
  %xbase = shl i32 %b, 4
  %pw64 = getelementptr inbounds i8, ptr %w, i32 %wb
  %word = load i64, ptr %pw64, align 8
  br label %pair
pair:
  %j = phi i32 [ 0, %block ], [ %j1, %pair ]
  %bs = phi float [ 0.0, %block ], [ %bs2, %pair ]
  %sh = shl i32 %j, 3
  %sh64 = zext i32 %sh to i64
  %shifted = lshr i64 %word, %sh64
  %byte = trunc i64 %shifted to i32
  %lo = and i32 %byte, 15
  %hi0 = lshr i32 %byte, 4
  %hi = and i32 %hi0, 15
  %vlo = call float @e2m1(i32 %lo)
  %vhi = call float @e2m1(i32 %hi)
  %j2 = shl i32 %j, 1
  %xi = add i32 %xbase, %j2
  %px0 = getelementptr inbounds float, ptr %x, i32 %xi
  %x0 = load float, ptr %px0, align 4
  %px1 = getelementptr inbounds float, ptr %px0, i32 1
  %x1 = load float, ptr %px1, align 4
  %t0 = call float @llvm.fma.f32(float %vlo, float %x0, float %bs)
  %bs2 = call float @llvm.fma.f32(float %vhi, float %x1, float %t0)
  %j1 = add i32 %j, 1
  %pdone = icmp eq i32 %j1, 8
  br i1 %pdone, label %blockend, label %pair
blockend:
  %acc1 = call float @llvm.fma.f32(float %scale, float %bs2, float %acc)
  %b1 = add i32 %b, %size
  %bdone = icmp uge i32 %b1, %blocks
  br i1 %bdone, label %reduce, label %block
reduce:
  %part = phi float [ 0.0, %start ], [ %acc1, %blockend ]
  %total = call float @kernel_subgroup_sum(float %part)
  %first = icmp eq i32 %lane, 0
  br i1 %first, label %store, label %done
store:
  %r = fmul float %total, %g
  %po = getelementptr inbounds float, ptr %out, i32 %row
  store float %r, ptr %po, align 4
  br label %done
done:
  ret void
}

declare float @kernel_subgroup_sum(float)

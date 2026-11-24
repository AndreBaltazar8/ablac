; CPU entry shims: the same bodies, the grid as a loop (a real backend splits it across threads).
target triple = "x86_64-unknown-linux-gnu"

define void @vadd_cpu(ptr %a, ptr %b, ptr %c, i32 %n) {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %loop ]
  call void @vadd.body(ptr %a, ptr %b, ptr %c, i32 %n, i32 %i)
  %i1 = add i32 %i, 1
  %d = icmp eq i32 %i1, %n
  br i1 %d, label %end, label %loop
end:
  ret void
}

define void @nvfp4dot_cpu(ptr %w, ptr %s, ptr %x, ptr %out, i32 %rows, i32 %k, float %g) {
entry:
  br label %loop
loop:
  %r = phi i32 [ 0, %entry ], [ %r1, %loop ]
  call void @nvfp4dot.body(ptr %w, ptr %s, ptr %x, ptr %out, i32 %rows, i32 %k, float %g, i32 %r)
  %r1 = add i32 %r, 1
  %d = icmp eq i32 %r1, %rows
  br i1 %d, label %end, label %loop
end:
  ret void
}

declare void @vadd.body(ptr, ptr, ptr, i32, i32)
declare void @nvfp4dot.body(ptr, ptr, ptr, ptr, i32, i32, float, i32)

; Subgroup of one lane on the CPU: the sum is the value itself.
define float @kernel_subgroup_sum(float %v) alwaysinline {
  ret float %v
}

define void @nvfp4dotSub_cpu(ptr %w, ptr %s, ptr %x, ptr %out, i32 %rows, i32 %k, float %g) {
entry:
  br label %loop
loop:
  %r = phi i32 [ 0, %entry ], [ %r1, %loop ]
  call void @nvfp4dotSub.body(ptr %w, ptr %s, ptr %x, ptr %out, i32 %rows, i32 %k, float %g, i32 %r, i32 0, i32 1)
  %r1 = add i32 %r, 1
  %d = icmp eq i32 %r1, %rows
  br i1 %d, label %end, label %loop
end:
  ret void
}

declare void @nvfp4dotSub.body(ptr, ptr, ptr, ptr, i32, i32, float, i32, i32, i32)

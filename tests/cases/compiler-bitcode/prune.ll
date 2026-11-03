source_filename = "prune"
module asm ".quad abla_fn_asm"
@callback = global ptr @abla_fn_callback
@nested = global [1 x ptr] [ptr @abla_fn_constant]
@literal = constant [13 x i8] c"abla_fn_text\00"
@alias = alias i32 (), ptr @abla_fn_alias

define i32 @main() {
  %result = call i32 @abla_fn_live()
  ret i32 %result
}

define hidden i32 @abla_fn_live() {
  %result = call i32 @helper()
  ret i32 %result
}

define internal i32 @helper() {
  ret i32 42
}

define hidden i32 @abla_fn_callback() {
  ret i32 1
}

define hidden i32 @abla_fn_constant() {
  ret i32 2
}

define hidden i32 @abla_fn_text() {
  ret i32 3
}

define hidden i32 @abla_fn_alias() {
  ret i32 4
}

define hidden i32 @abla_fn_asm() {
  ret i32 5
}

define hidden i32 @abla_fn_dead_a() {
  %result = call i32 @abla_fn_dead_b()
  ret i32 %result
}

define hidden i32 @abla_fn_dead_b() {
  %result = call i32 @abla_fn_dead_a()
  ret i32 %result
}

define internal i32 @dead_helper() {
  ret i32 6
}

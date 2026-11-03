@address = global ptr @tiny
@bridge_address = global ptr @bridge
@private_address = global ptr @private_bridge
@forward = alias i64 (i64), ptr @bridge
@bridge = alias i64 (i64), ptr @tiny
@private_bridge = internal alias i64 (i64), ptr @forward
@datum = internal global i64 23
@data_alias = alias i64, ptr @datum
@data_address = global ptr @data_alias

define internal i64 @tiny(i64 %x) {
  %r = add i64 %x, 7
  ret i64 %r
}
define i64 @first(i64 %x) {
  %r = call i64 @tiny(i64 %x)
  ret i64 %r
}
define i64 @second(i64 %x) {
  %r = call i64 @tiny(i64 %x)
  ret i64 %r
}
define i32 @main() {
  %a = call i64 @first(i64 1)
  %b = call i64 @second(i64 2)
  %c = call i64 @bridge(i64 3)
  %p = load ptr, ptr @address
  %q = load ptr, ptr @bridge_address
  %private = load ptr, ptr @private_address
  %data = load ptr, ptr @data_address
  %value = load i64, ptr @data_alias
  %same = icmp eq ptr %p, @tiny
  %alias = icmp eq ptr @bridge, @tiny
  %escaped = icmp eq ptr %q, @tiny
  %chained = icmp eq ptr @forward, @tiny
  %private_same = icmp eq ptr @private_bridge, @tiny
  %private_escaped = icmp eq ptr %private, @tiny
  %same_data = icmp eq ptr @data_alias, @datum
  %escaped_data = icmp eq ptr %data, @datum
  %value_ok = icmp eq i64 %value, 23
  %aok = icmp eq i64 %a, 8
  %bok = icmp eq i64 %b, 9
  %cok = icmp eq i64 %c, 10
  %ab = and i1 %aok, %bok
  %abc = and i1 %ab, %cok
  %ptrs = and i1 %same, %alias
  %ptrs2 = and i1 %ptrs, %escaped
  %ptrs3 = and i1 %ptrs2, %chained
  %private_ptrs = and i1 %private_same, %private_escaped
  %ptrs4 = and i1 %ptrs3, %private_ptrs
  %data_ok = and i1 %same_data, %escaped_data
  %data_ok2 = and i1 %data_ok, %value_ok
  %ok1 = and i1 %abc, %ptrs4
  %ok = and i1 %ok1, %data_ok2
  %status = select i1 %ok, i32 0, i32 1
  ret i32 %status
}

const std = @import("std");
extern "c" fn json_tokener_parse([*:0]const u8) ?*anyopaque;
extern "c" fn json_object_to_json_string_ext(*anyopaque, c_int) [*:0]const u8;
extern "c" fn json_object_put(*anyopaque) c_int;
extern "c" fn puts([*:0]const u8) c_int;
pub fn main() !void {
    const a = std.heap.c_allocator;
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    const n = try std.fmt.parseInt(usize, args[1], 10);
    const bytes = try std.fs.cwd().readFileAllocOptions(a, args[2], 1 << 26, null, @alignOf(u8), 0);
    defer a.free(bytes);
    for (0..n) |i| {
        const v = json_tokener_parse(bytes) orelse return error.Parse;
        const out = json_object_to_json_string_ext(v, 0);
        if (i == n - 1) {
            _ = puts(out);
        }
        _ = json_object_put(v);
    }
}

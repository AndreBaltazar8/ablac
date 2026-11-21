const std = @import("std");
const cpu = @import("cpu.zig");
pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    cpu.nBody(try std.fmt.parseInt(usize, args[1], 10));
}

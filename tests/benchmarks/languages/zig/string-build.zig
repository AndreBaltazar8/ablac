const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const count = try std.fmt.parseInt(usize, args[1], 10);
    var text = std.ArrayList(u8).init(allocator);
    defer text.deinit();
    for (0..count) |i| {
        const chunk = if (i % 2 == 0) "alpha: 01234567\n" else "bravo: 76543210\n";
        try text.appendSlice(chunk);
    }
    try std.io.getStdOut().writeAll(text.items);
}

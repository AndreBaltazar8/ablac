const std = @import("std");
extern "c" fn pcre2_compile_8([*]const u8, usize, u32, *c_int, *usize, ?*anyopaque) ?*anyopaque;
extern "c" fn pcre2_match_data_create_from_pattern_8(*anyopaque, ?*anyopaque) *anyopaque;
extern "c" fn pcre2_match_8(*anyopaque, [*]const u8, usize, usize, u32, *anyopaque, ?*anyopaque) c_int;
extern "c" fn pcre2_get_ovector_pointer_8(*anyopaque) [*]usize;
extern "c" fn pcre2_match_data_free_8(*anyopaque) void;
extern "c" fn pcre2_code_free_8(*anyopaque) void;
extern "c" fn printf([*:0]const u8, ...) c_int;
const alloc = std.heap.c_allocator;
const Regex = struct {
    c: *anyopaque,
    md: *anyopaque,
    fn init(p: []const u8) Regex {
        var e: c_int = 0;
        var at: usize = 0;
        const c = pcre2_compile_8(p.ptr, p.len, 0, &e, &at, null) orelse @panic("regex compile");
        return .{ .c = c, .md = pcre2_match_data_create_from_pattern_8(c, null) };
    }
    fn deinit(self: Regex) void {
        pcre2_match_data_free_8(self.md);
        pcre2_code_free_8(self.c);
    }
    fn find(self: Regex, s: []const u8, at: usize) ?[2]usize {
        const r = pcre2_match_8(self.c, s.ptr, s.len, at, 0, self.md, null);
        if (r == -1) return null;
        if (r < 0) @panic("regex match");
        const v = pcre2_get_ovector_pointer_8(self.md);
        return .{ v[0], v[1] };
    }
    fn replace(self: Regex, s: []const u8, r: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(alloc);
        errdefer out.deinit();
        var at: usize = 0;
        while (self.find(s, at)) |v| {
            try out.appendSlice(s[at..v[0]]);
            try out.appendSlice(r);
            at = v[1];
        }
        try out.appendSlice(s[at..]);
        return out.toOwnedSlice();
    }
};
pub fn main() !void {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const input = try std.fs.cwd().readFileAlloc(alloc, args[2], 1 << 26);
    defer alloc.free(input);
    const clean = Regex.init(">[^\n]*\n|\n");
    defer clean.deinit();
    var s = try clean.replace(input, "");
    defer alloc.free(s);
    const cleaned = s.len;
    const patterns = [_][:0]const u8{ "agggtaaa|tttaccct", "[cgt]gggtaaa|tttaccc[acg]", "a[act]ggtaaa|tttacc[agt]t", "ag[act]gtaaa|tttac[agt]ct", "agg[act]taaa|ttta[agt]cct", "aggg[acg]aaa|ttt[cgt]ccct", "agggt[cgt]aa|tt[acg]accct", "agggta[cgt]a|t[acg]taccct", "agggtaa[cgt]|[acg]ttaccct" };
    for (patterns) |p| {
        const re = Regex.init(p);
        defer re.deinit();
        var count: usize = 0;
        var at: usize = 0;
        while (re.find(s, at)) |v| {
            count += 1;
            at = v[1];
        }
        _ = printf("%s %zu\n", p.ptr, count);
    }
    const p = [_][]const u8{ "tHa[Nt]", "aND|caN|Ha[DS]|WaS", "a[NSt]|BY", "<[^>]*>", "\\|[^|][^|]*\\|" };
    const r = [_][]const u8{ "<4>", "<3>", "<2>", "|", "-" };
    for (p, r) |pattern, rep| {
        const re = Regex.init(pattern);
        defer re.deinit();
        const next = try re.replace(s, rep);
        alloc.free(s);
        s = next;
    }
    _ = printf("\n%zu\n%zu\n%zu\n", input.len, cleaned, s.len);
}

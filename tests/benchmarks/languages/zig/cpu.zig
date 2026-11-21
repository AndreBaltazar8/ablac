const std = @import("std");
extern "c" fn printf([*:0]const u8, ...) c_int;
extern "c" fn putchar(c_int) c_int;
extern "c" fn puts([*:0]const u8) c_int;
const alloc = std.heap.c_allocator;
const Tree = struct { left: ?*Tree, right: ?*Tree };
fn make(d: usize) *Tree {
    const t = alloc.create(Tree) catch @panic("alloc");
    t.* = .{ .left = if (d > 0) make(d - 1) else null, .right = if (d > 0) make(d - 1) else null };
    return t;
}
fn check(t: *Tree) i64 {
    return if (t.left) |l| 1 + check(l) + check(t.right.?) else 1;
}
fn drop(t: *Tree) void {
    if (t.left) |l| {
        drop(l);
        drop(t.right.?);
    }
    alloc.destroy(t);
}
pub fn binaryTrees(n: usize) void {
    const t = make(n + 1);
    _ = printf("stretch %ld\n", check(t));
    drop(t);
    const long = make(n);
    var d: usize = 4;
    while (d <= n) : (d += 2) {
        const rounds = @as(usize, 1) << @intCast(n - d + 4);
        var sum: i64 = 0;
        for (0..rounds) |_| {
            const x = make(d);
            sum += check(x);
            drop(x);
        }
        _ = printf("%zu %zu %ld\n", d, rounds, sum);
    }
    _ = printf("long %ld\n", check(long));
    drop(long);
}
pub fn fannkuch(n: usize) void {
    var p: [16]usize = undefined;
    var q: [16]usize = undefined;
    var count: [16]usize = undefined;
    for (0..n) |i| p[i] = i;
    var r = n;
    var maximum: i64 = 0;
    var checksum: i64 = 0;
    var idx: usize = 0;
    while (true) {
        while (r != 1) {
            count[r - 1] = r;
            r -= 1;
        }
        @memcpy(q[0..n], p[0..n]);
        var flips: i64 = 0;
        while (q[0] != 0) {
            var i: usize = 0;
            var j = q[0];
            while (i < j) {
                const tmp = q[i];
                q[i] = q[j];
                q[j] = tmp;
                i += 1;
                j -= 1;
            }
            flips += 1;
        }
        maximum = @max(maximum, flips);
        checksum += if (idx % 2 == 0) flips else -flips;
        idx += 1;
        while (true) {
            if (r == n) {
                _ = printf("%ld %ld\n", checksum, maximum);
                return;
            }
            const first = p[0];
            for (0..r) |i| p[i] = p[i + 1];
            p[r] = first;
            count[r] -= 1;
            if (count[r] > 0) break;
            r += 1;
        }
    }
}
fn a(i: usize, j: usize) f64 {
    return 1.0 / @as(f64, @floatFromInt((i + j) * (i + j + 1) / 2 + i + 1));
}
fn mul(u: []f64, v: []f64, transpose: bool) void {
    for (0..u.len) |i| {
        var s: f64 = 0;
        for (0..u.len) |j| s += (if (transpose) a(j, i) else a(i, j)) * u[j];
        v[i] = s;
    }
}
pub fn spectralNorm(n: usize) void {
    const u = alloc.alloc(f64, n) catch @panic("alloc");
    defer alloc.free(u);
    const v = alloc.alloc(f64, n) catch @panic("alloc");
    defer alloc.free(v);
    const t = alloc.alloc(f64, n) catch @panic("alloc");
    defer alloc.free(t);
    @memset(u, 1);
    for (0..10) |_| {
        mul(u, t, false);
        mul(t, v, true);
        mul(v, t, false);
        mul(t, u, true);
    }
    var uv: f64 = 0;
    var vv: f64 = 0;
    for (0..n) |i| {
        uv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    _ = printf("%.9f\n", @sqrt(uv / vv));
}
pub fn mandelbrot(n: usize) void {
    _ = printf("P4\n%zu %zu\n", n, n);
    const nf: f64 = @floatFromInt(n);
    for (0..n) |y| {
        var byte: c_int = 0;
        var bits: u5 = 0;
        for (0..n) |x| {
            const cr = 2.0 * @as(f64, @floatFromInt(x)) / nf - 1.5;
            const ci = 2.0 * @as(f64, @floatFromInt(y)) / nf - 1.0;
            var zr: f64 = 0;
            var zi: f64 = 0;
            var k: usize = 0;
            while (k < 50 and zr * zr + zi * zi <= 4) {
                const next = zr * zr - zi * zi + cr;
                zi = 2 * zr * zi + ci;
                zr = next;
                k += 1;
            }
            byte = (byte << 1) | @as(c_int, @intFromBool(zr * zr + zi * zi <= 4));
            bits += 1;
            if (bits == 8) {
                _ = putchar(byte);
                byte = 0;
                bits = 0;
            }
        }
        if (bits > 0) {
            _ = putchar(byte << (@as(u5, 8) - bits));
        }
    }
}
const alu = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";
var seed: u32 = 42;
fn random(n: usize, letters: []const u8, prob: []const f64) void {
    for (0..n) |i| {
        seed = (seed * 3877 + 29573) % 139968;
        const r = @as(f64, @floatFromInt(seed)) / 139968;
        var j: usize = 0;
        var c: f64 = 0;
        while (j < letters.len - 1) {
            c += prob[j];
            if (r < c) break;
            j += 1;
        }
        _ = putchar(letters[j]);
        if (i % 60 == 59 or i == n - 1) {
            _ = putchar(10);
        }
    }
}
pub fn fasta(n: usize) void {
    _ = puts(">ONE Homo sapiens alu");
    for (0..2 * n) |i| {
        _ = putchar(alu[i % alu.len]);
        if (i % 60 == 59 or i == 2 * n - 1) {
            _ = putchar(10);
        }
    }
    _ = puts(">TWO IUB ambiguity codes");
    random(3 * n, "acgtBDHKMNRSVWY", &.{ 0.27, 0.12, 0.12, 0.27, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02 });
    _ = puts(">THREE Homo sapiens frequency");
    random(5 * n, "acgt", &.{ 0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008 });
}
const Body = struct { x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, m: f64 };
fn energy(b: []Body) f64 {
    var e: f64 = 0;
    for (0..5) |i| {
        const v = b[i];
        e += 0.5 * v.m * (v.vx * v.vx + v.vy * v.vy + v.vz * v.vz);
        for (i + 1..5) |j| {
            const dx = v.x - b[j].x;
            const dy = v.y - b[j].y;
            const dz = v.z - b[j].z;
            e -= v.m * b[j].m / @sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}
pub fn nBody(n: usize) void {
    const sm = 39.47841760435743;
    const yr = 365.24;
    var b = [_]Body{ .{ .x = 0, .y = 0, .z = 0, .vx = 0, .vy = 0, .vz = 0, .m = sm }, .{ .x = 4.84143144246472090, .y = -1.16032004402742839, .z = -0.103622044471123109, .vx = 0.00166007664274403694 * yr, .vy = 0.00769901118419740425 * yr, .vz = -0.0000690460016972063023 * yr, .m = 0.000954791938424326609 * sm }, .{ .x = 8.34336671824457987, .y = 4.12479856412430479, .z = -0.403523417114321381, .vx = -0.00276742510726862411 * yr, .vy = 0.00499852801234917238 * yr, .vz = 0.0000230417297573763929 * yr, .m = 0.000285885980666130812 * sm }, .{ .x = 12.8943695621391310, .y = -15.1111514016986312, .z = -0.223307578892655734, .vx = 0.00296460137564761618 * yr, .vy = 0.00237847173959480950 * yr, .vz = -0.0000296589568540237556 * yr, .m = 0.0000436624404335156298 * sm }, .{ .x = 15.3796971148509165, .y = -25.9193146099879641, .z = 0.179258772950371181, .vx = 0.00268067772490389322 * yr, .vy = 0.00162824170038242295 * yr, .vz = -0.0000951592254519715870 * yr, .m = 0.0000515138902046611451 * sm } };
    for (0..5) |i| {
        b[0].vx -= b[i].vx * b[i].m / sm;
        b[0].vy -= b[i].vy * b[i].m / sm;
        b[0].vz -= b[i].vz * b[i].m / sm;
    }
    _ = printf("%.9f\n", energy(&b));
    for (0..n) |_| {
        for (0..5) |i| {
            for (i + 1..5) |j| {
                const dx = b[i].x - b[j].x;
                const dy = b[i].y - b[j].y;
                const dz = b[i].z - b[j].z;
                const d2 = dx * dx + dy * dy + dz * dz;
                const mag = 0.01 / (d2 * @sqrt(d2));
                b[i].vx -= dx * b[j].m * mag;
                b[i].vy -= dy * b[j].m * mag;
                b[i].vz -= dz * b[j].m * mag;
                b[j].vx += dx * b[i].m * mag;
                b[j].vy += dy * b[i].m * mag;
                b[j].vz += dz * b[i].m * mag;
            }
        }
        for (&b) |*v| {
            v.x += 0.01 * v.vx;
            v.y += 0.01 * v.vy;
            v.z += 0.01 * v.vz;
        }
    }
    _ = printf("%.9f\n", energy(&b));
}

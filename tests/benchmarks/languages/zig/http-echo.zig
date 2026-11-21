const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("unistd.h");
});
pub fn main() !void {
    const a = std.heap.c_allocator;
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.Socket;
    var yes: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7f000001);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0 or c.listen(fd, 128) != 0) return error.Bind;
    while (true) {
        const client = c.accept(fd, null, null);
        if (client < 0) return error.Accept;
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        while (n < buf.len) {
            const r = c.read(client, buf[n..].ptr, buf.len - n);
            if (r <= 0) break;
            n += @intCast(r);
            if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |at| {
                if (n >= at + 4 + 256) {
                    const header = "HTTP/1.1 200 OK\r\nContent-Length: 256\r\nConnection: close\r\n\r\n";
                    var response: [header.len + 256]u8 = undefined;
                    @memcpy(response[0..header.len], header);
                    @memcpy(response[header.len..], buf[at + 4 .. at + 4 + 256]);
                    var sent: usize = 0;
                    while (sent < response.len) {
                        const wrote = c.send(client, response[sent..].ptr, response.len - sent, c.MSG_NOSIGNAL);
                        if (wrote <= 0) break;
                        sent += @intCast(wrote);
                    }
                    break;
                }
            }
        }
        _ = c.close(client);
    }
}

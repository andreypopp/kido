const std = @import("std");
const terminfo = @import("terminfo");
extern "c" fn write(c_int, [*]const u8, usize) isize;
pub fn main() void {
    var bytes: [65536]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    terminfo.ghostty.encode(&writer) catch @panic("terminfo exceeds buffer");
    const data = writer.buffered();
    var pos: usize = 0;
    while (pos < data.len) {
        const n = write(1, data.ptr + pos, data.len - pos);
        if (n <= 0) @panic("write terminfo");
        pos += @intCast(n);
    }
}

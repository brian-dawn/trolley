const std = @import("std");

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("Hello from trolley!\n\n");
    try stdout.writeAll("This is a minimal trolley example.\n\n");

    const hello_from = std.posix.getenv("HELLO_FROM") orelse "(not set)";
    const lang = std.posix.getenv("LANG") orelse "(not set)";

    var buf: [256]u8 = undefined;
    var written = std.fmt.bufPrint(&buf, "HELLO_FROM = {s}\n", .{hello_from}) catch "(fmt error)";
    try stdout.writeAll(written);
    written = std.fmt.bufPrint(&buf, "LANG       = {s}\n\n", .{lang}) catch "(fmt error)";
    try stdout.writeAll(written);

    try stdout.writeAll("Press Enter to exit.\n");

    const stdin = std.fs.File.stdin();
    var read_buf: [1]u8 = undefined;
    _ = stdin.read(&read_buf) catch {};
}

const std = @import("std");
const os = std.os;
const net = std.net;
const IO = @import("io").IO;
const builtin = @import("builtin");
const Server = @import("Server.zig");

pub fn main() !void {
    if (builtin.os.tag != .windows) {
        const act = os.Sigaction{
            .handler = .{ .handler = os.SIG.IGN },
            .mask = os.empty_sigset,
            .flags = 0,
        };
        try os.sigaction(os.SIG.PIPE, &act, null);
    }

    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = Server.init(io);
    defer server.deinit();

    try server.startServe("127.0.0.1", 1081);
}

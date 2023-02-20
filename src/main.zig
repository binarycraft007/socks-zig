const std = @import("std");
const os = std.os;
const net = std.net;
const builtin = @import("builtin");
const Server = @import("Server.zig");
const ThreadPool = @import("ThreadPool.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(
        std.heap.page_allocator,
    );
    defer arena.deinit();

    var allocator = arena.allocator();

    if (builtin.os.tag == .windows)
        _ = try os.windows.WSAStartup(2, 2);

    defer {
        if (builtin.os.tag == .windows)
            os.windows.WSACleanup() catch unreachable;
    }

    if (builtin.os.tag != .windows) {
        const act = os.Sigaction{
            .handler = .{ .handler = os.SIG.IGN },
            .mask = os.empty_sigset,
            .flags = 0,
        };
        try os.sigaction(os.SIG.PIPE, &act, null);
    }

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(allocator);
    defer thread_pool.deinit();

    var server = try Server.init(&thread_pool);
    defer server.deinit();

    try server.startServe("127.0.0.1", 1081);
}

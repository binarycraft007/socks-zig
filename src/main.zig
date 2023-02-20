const std = @import("std");
const os = std.os;
const net = std.net;
const Server = @import("Server.zig");
const ThreadPool = @import("ThreadPool.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(
        std.heap.page_allocator,
    );
    defer arena.deinit();

    var allocator = arena.allocator();

    const sigact = os.Sigaction{
        .handler = .{ .handler = os.SIG.IGN },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    try os.sigaction(os.SIG.PIPE, &sigact, null);

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(allocator);
    defer thread_pool.deinit();

    var server = try Server.init(&thread_pool);
    defer server.deinit();

    try server.startServe("127.0.0.1", 1081);
}

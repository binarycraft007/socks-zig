const std = @import("std");
const IO = @import("io").IO;
const default = @import("default.zig");
const Server = @import("Server.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(
        std.heap.page_allocator,
    );
    defer arena.deinit();

    var allocator = arena.allocator();

    const config = Server.Config{
        .bind_host = default.bind_host,
        .bind_port = default.bind_port,
        .idle_timeout = default.idle_timeout,
    };

    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = Server.init(allocator, io, config);
    defer server.deinit();

    try server.run();
}

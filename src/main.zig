const std = @import("std");
const Server = @import("Server.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(
        std.heap.page_allocator,
    );
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try Server.init(
        allocator,
        .{ .address = "127.0.0.1", .port = 1081 },
    );
    defer server.deinit();

    try server.acceptLoop();
}

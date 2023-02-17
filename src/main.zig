const std = @import("std");
const Server = @import("Server.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try Server.init(allocator);
    defer server.deinit();

    try server.acceptLoop();
}

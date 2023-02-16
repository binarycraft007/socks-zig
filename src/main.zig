const std = @import("std");
const IO = @import("io").IO;

pub fn main() !void {
    var io = try IO.init(32, 0);
    defer io.deinit();
}

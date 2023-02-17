const std = @import("std");
const IO = @import("io").IO;
const ThreadPool = @import("ThreadPool.zig");
const WaitGroup = @import("WaitGroup.zig");
const os = std.os;
const mem = std.mem;
const log = std.log;
const net = std.net;
const fmt = std.fmt;

const Server = @This();

io: IO,
stream_server: net.StreamServer,
thread_pool: ThreadPool = undefined,

pub const AddressType = enum(u8) {
    ipv4_addr = 0x01,
    domain_name = 0x03,
    ipv6_addr = 0x04,
};

pub const Command = enum(u8) {
    connect = 0x01,
    bind = 0x02,
    associate = 0x03,
};

pub const MetaData = struct {
    command: Command,
    address: net.Address,
};

pub fn init(allocator: mem.Allocator) !Server {
    const localhost = try net.Address.parseIp("127.0.0.1", 1080);
    var server = Server{
        .io = try IO.init(32, 0),
        .stream_server = net.StreamServer.init(.{
            .kernel_backlog = 32,
            .reuse_address = true,
        }),
    };
    try server.thread_pool.init(allocator);
    try server.stream_server.listen(localhost);

    return server;
}

pub fn deinit(self: *Server) void {
    self.io.deinit();
    self.thread_pool.deinit();
    self.stream_server.deinit();
}

pub fn acceptLoop(self: *Server) !void {
    while (true) {
        var wg = WaitGroup{};
        var conn = try self.stream_server.accept();
        defer conn.stream.close();

        wg.start();
        try self.thread_pool.spawn(clientHandler, .{ conn.stream, &wg });
        self.thread_pool.waitAndWork(&wg);
    }
}

pub fn clientHandler(stream: net.Stream, wg: *WaitGroup) void {
    defer wg.finish();

    var metadata = handshakeHandler(stream);
    log.info("received socks cmd: {s}", .{@tagName(metadata.command)});

    switch (metadata.command) {
        .connect => {
            connect(stream);
        },
        .associate => {},
        .bind => {
            log.err("bind command is not supported", .{});
            return;
        },
    }
}

/// +----+-----+-------+------+----------+----------+
/// |VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
/// +----+-----+-------+------+----------+----------+
/// | 1  |  1  | X'00' |  1   | Variable |    2     |
/// +----+-----+-------+------+----------+----------+
pub fn connect(stream: net.Stream) void {
    var buf = [_]u8{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    _ = stream.writer().write(&buf) catch |err| {
        @panic(@errorName(err));
    };
}

/// +----+----------+----------+  +----+--------+
/// |VER | NMETHODS | METHODS  |  |VER | METHOD |
/// +----+----------+----------+  +----+--------+
/// | 1  |    1     | 1 to 255 |  | 1  |   1    |
/// +----+----------+----------+  +----+--------+
pub fn handshakeHandler(stream: net.Stream) MetaData {
    var version = stream.reader().readBoundedBytes(1) catch |err| {
        @panic(@errorName(err));
    };

    if (version.slice()[0] != 5) {
        @panic("only socks version 5 is supported");
    }

    var nmethods = stream.reader().readBoundedBytes(1) catch |err| {
        @panic(@errorName(err));
    };

    var methods: [255]u8 = [_]u8{0} ** 255;
    _ = stream.reader().read(methods[0..nmethods.slice()[0]]) catch |err| {
        @panic(@errorName(err));
    };

    _ = stream.writer().write(&[_]u8{ 5, 0x0 }) catch |err| {
        @panic(@errorName(err));
    };

    var cmd_buf = stream.reader().readBoundedBytes(3) catch |err| {
        @panic(@errorName(err));
    };

    return MetaData{
        .command = @intToEnum(Command, cmd_buf.slice()[1]),
        .address = readAddress(stream),
    };
}

pub fn readAddress(stream: net.Stream) net.Address {
    var port: u16 = undefined;
    var addr: []u8 = undefined;

    var addr_type = stream.reader().readBoundedBytes(1) catch |err| {
        @panic(@errorName(err));
    };

    switch (@intToEnum(AddressType, addr_type.slice()[0])) {
        .ipv4_addr => {
            var buf: [15]u8 = undefined;

            var addr_str = stream.reader().readBoundedBytes(4) catch |err| {
                @panic(@errorName(err));
            };
            var port_str = stream.reader().readBoundedBytes(2) catch |err| {
                @panic(@errorName(err));
            };

            var addr_slice = addr_str.slice();
            var port_slice = port_str.slice();

            addr = fmt.bufPrint(
                &buf,
                "{}.{}.{}.{}",
                .{ addr_slice[0], addr_slice[1], addr_slice[2], addr_slice[3] },
            ) catch |err| @panic(@errorName(err));

            port = @as(u16, port_slice[0]) << 8 | @as(u16, port_slice[1]);
            log.info("destination address: {s}:{d}", .{ addr, port });
        },
        .domain_name => {
            @panic("domain name unimplemented");
        },
        .ipv6_addr => {
            @panic("ipv6 address unimplemented");
        },
    }
    return net.Address.parseIp(addr, port) catch |err| @panic(@errorName(err));
}

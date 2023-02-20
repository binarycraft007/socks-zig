const std = @import("std");
const log = std.log;
const fmt = std.fmt;
const mem = std.mem;
const net = std.net;
const ThreadPool = @import("ThreadPool.zig");
const WaitGroup = @import("WaitGroup.zig");
const Server = @This();

thread_pool: *ThreadPool = undefined,
stream_server: net.StreamServer,

pub fn init(thread_pool: *ThreadPool) !Server {
    var stream_server = net.StreamServer.init(.{});

    return Server{
        .thread_pool = thread_pool,
        .stream_server = stream_server,
    };
}

pub fn deinit(self: *Server) void {
    self.thread_pool.deinit();
    self.stream_server.deinit();
}

pub fn startServe(self: *Server, listen_ip: []const u8, port: u16) !void {
    const listen_addr = try net.Address.parseIp(listen_ip, port);
    try self.stream_server.listen(listen_addr);

    while (true) {
        var wg: WaitGroup = .{};
        defer self.thread_pool.waitAndWork(&wg);

        for (self.thread_pool.threads) |_| {
            wg.start();
            try self.thread_pool.spawn(worker, .{ &self.stream_server, &wg });
        }
    }
}

fn worker(server: *net.StreamServer, wg: *WaitGroup) void {
    defer wg.finish();

    var client = server.accept() catch |err| {
        std.log.err("accept error: {s}", .{@errorName(err)});
        return;
    };
    defer client.stream.close();

    std.log.info("got client connection: {d}", .{client.stream.handle});

    var metadata = handshakeHandler(client.stream) catch |err| {
        log.scoped(.handshake).err("{s}", .{@errorName(err)});
        return;
    };
    log.info("received socks cmd: {s}", .{@tagName(metadata.command)});

    switch (metadata.command) {
        .connect => {
            log.info("try to connect to addr: {any}", .{metadata.address});

            var remote = connectHandler(client.stream, metadata) catch |err| {
                log.scoped(.connect).err("{s}", .{@errorName(err)});
                return;
            };
            defer remote.close();

            log.info("addr: {any} connect success", .{metadata.address});
            //var event_loop = EventLoop.init(stream, remote) catch |err| {
            //    log.scoped(.connect).err("{s}", .{@errorName(err)});
            //    return;
            //};
            //event_loop.copyLoop() catch |err| {
            //    log.scoped(.connect).err("{s}", .{@errorName(err)});
            //    return;
            //};
        },
        .associate => {},
        .bind => {
            log.scoped(.bind).err("BindCommandUnsupported", .{});
            return;
        },
    }
}

/// +----+-----+-------+------+----------+----------+
/// |VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
/// +----+-----+-------+------+----------+----------+
/// | 1  |  1  | X'00' |  1   | Variable |    2     |
/// +----+-----+-------+------+----------+----------+
pub fn connectHandler(stream: net.Stream, metadata: MetaData) !net.Stream {
    var remote = net.tcpConnectToAddress(metadata.address) catch |err| {
        var fail = [_]u8{ 5, 4, 0, 1, 0, 0, 0, 0, 0, 0 };
        _ = try stream.writer().write(&fail);
        return err;
    };

    var success = [_]u8{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    _ = try stream.writer().write(&success);

    return remote;
}

/// +----+----------+----------+  +----+--------+
/// |VER | NMETHODS | METHODS  |  |VER | METHOD |
/// +----+----------+----------+  +----+--------+
/// | 1  |    1     | 1 to 255 |  | 1  |   1    |
/// +----+----------+----------+  +----+--------+
pub fn handshakeHandler(stream: net.Stream) !MetaData {
    var version = try stream.reader().readBoundedBytes(1);

    if (version.slice()[0] != 5) {
        return error.SocksVersionUnsupported;
    }

    var nmethods = try stream.reader().readBoundedBytes(1);

    var methods: [255]u8 = [_]u8{0} ** 255;
    _ = try stream.reader().read(methods[0..nmethods.slice()[0]]);

    _ = try stream.writer().write(&[_]u8{ 5, 0x0 });

    var cmd_buf = try stream.reader().readBoundedBytes(3);

    log.info("handshake success, stream: {d}", .{stream.handle});
    return MetaData{
        .command = @intToEnum(Command, cmd_buf.slice()[1]),
        .address = try readAddress(stream),
    };
}

pub fn readAddress(stream: net.Stream) !net.Address {
    var port: u16 = undefined;
    var addr: []u8 = undefined;

    var addr_type = try stream.reader().readBoundedBytes(1);

    switch (@intToEnum(AddressType, addr_type.slice()[0])) {
        .ipv4_addr => {
            var buf: [15]u8 = undefined;

            var addr_str = try stream.reader().readBoundedBytes(4);
            var port_str = try stream.reader().readBoundedBytes(2);

            var addr_s = addr_str.slice();
            var port_s = port_str.slice();

            addr = try fmt.bufPrint(
                &buf,
                "{}.{}.{}.{}",
                .{ addr_s[0], addr_s[1], addr_s[2], addr_s[3] },
            );

            port = @as(u16, port_s[0]) << 8 | @as(u16, port_s[1]);
        },
        .domain_name => {
            return error.DomainNameUnimplemented;
        },
        .ipv6_addr => {
            return error.Ipv6AddressUnimplemented;
        },
    }
    return try net.Address.parseIp(addr, port);
}

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

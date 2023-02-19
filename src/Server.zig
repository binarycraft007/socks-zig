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

pub const InitOptions = struct {
    address: []const u8,
    port: u16,
};

pub fn init(allocator: mem.Allocator, opts: InitOptions) !Server {
    const addr = try net.Address.parseIp(opts.address, opts.port);
    var server = Server{
        .stream_server = net.StreamServer.init(
            .{ .kernel_backlog = 32, .reuse_address = true },
        ),
    };
    try server.thread_pool.init(allocator);
    try server.stream_server.listen(addr);

    return server;
}

pub fn deinit(self: *Server) void {
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

    var metadata = handshakeHandler(stream) catch |err| {
        log.scoped(.handshake).err("{s}", .{@errorName(err)});
        return;
    };
    log.info("received socks cmd: {s}", .{@tagName(metadata.command)});

    switch (metadata.command) {
        .connect => {
            log.info("try to connect to addr: {any}", .{metadata.address});

            var remote = connectHandler(stream, metadata) catch |err| {
                log.scoped(.connect).err("{s}", .{@errorName(err)});
                return;
            };
            defer remote.close();

            log.info("addr: {any} connect success", .{metadata.address});
            var event_loop = EventLoop.init(stream, remote) catch |err| {
                log.scoped(.connect).err("{s}", .{@errorName(err)});
                return;
            };
            event_loop.copyLoop() catch |err| {
                log.scoped(.connect).err("{s}", .{@errorName(err)});
                return;
            };
        },
        .associate => {},
        .bind => {
            log.scoped(.bind).err("BindCommandUnsupported", .{});
            return;
        },
    }
}

pub const EventLoop = struct {
    const Self = @This();
    io: IO,
    client: net.Stream,
    remote: net.Stream,
    read_n: usize = 0,
    write_n: usize = 0,
    buffer: [1024]u8 = [_]u8{0} ** 1024,
    client_read_done: bool = false,
    remote_read_done: bool = false,
    client_read_once_done: bool = false,
    remote_read_once_done: bool = false,

    pub fn init(client: net.Stream, remote: net.Stream) !Self {
        return Self{
            .client = client,
            .remote = remote,
            .io = try IO.init(32, 0),
        };
    }

    pub fn copyLoop(self: *Self) !void {
        // Start receiving on the client
        while (true) {
            var client_read_completion: IO.Completion = undefined;
            self.io.read(
                *EventLoop,
                self,
                on_read_client,
                &client_read_completion,
                self.client.handle,
                &self.buffer,
                0,
            );

            while (!self.client_read_once_done) try self.io.tick();
            self.client_read_once_done = false;

            if (self.client_read_done) {
                break;
            }
        }

        while (true) {
            var remote_read_completion: IO.Completion = undefined;
            self.io.read(
                *EventLoop,
                self,
                on_read_remote,
                &remote_read_completion,
                self.remote.handle,
                &self.buffer,
                0,
            );

            while (!self.remote_read_once_done) try self.io.tick();
            self.remote_read_once_done = false;

            if (self.remote_read_done) {
                break;
            }
        }
    }

    fn on_read_client(
        self: *EventLoop,
        completion: *IO.Completion,
        result: IO.ReadError!usize,
    ) void {
        self.read_n = result catch |err| @panic(@errorName(err));

        self.io.write(
            *EventLoop,
            self,
            on_write_remote,
            completion,
            self.remote.handle,
            self.buffer[0..self.read_n],
            0,
        );
    }

    fn on_write_remote(
        self: *EventLoop,
        completion: *IO.Completion,
        result: IO.WriteError!usize,
    ) void {
        _ = completion;
        self.write_n = result catch |err| @panic(@errorName(err));
        self.client_read_once_done = true;

        if (self.write_n < self.buffer.len) {
            self.client_read_done = true;
        }
    }

    fn on_read_remote(
        self: *EventLoop,
        completion: *IO.Completion,
        result: IO.ReadError!usize,
    ) void {
        self.read_n = result catch |err| @panic(@errorName(err));

        self.io.write(
            *EventLoop,
            self,
            on_write_client,
            completion,
            self.client.handle,
            self.buffer[0..self.read_n],
            0,
        );
    }

    fn on_write_client(
        self: *EventLoop,
        completion: *IO.Completion,
        result: IO.WriteError!usize,
    ) void {
        _ = completion;
        self.write_n = result catch |err| @panic(@errorName(err));
        self.remote_read_once_done = true;

        if (self.write_n < self.buffer.len) {
            self.remote_read_done = true;
        }
    }
};

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

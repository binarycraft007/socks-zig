const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const log = std.log;
const fmt = std.fmt;
const mem = std.mem;
const net = std.net;
const meta = std.meta;
const ThreadPool = @import("ThreadPool.zig");
const WaitGroup = @import("WaitGroup.zig");
const windows = std.os.windows;
const Server = @This();

allocator: mem.Allocator,
thread_pool: *ThreadPool = undefined,
stream_server: net.StreamServer,

const InitOptions = struct {
    allocator: mem.Allocator,
    thread_pool: *ThreadPool,
};

pub fn init(opts: InitOptions) !Server {
    var stream_server = net.StreamServer.init(.{});

    return Server{
        .allocator = opts.allocator,
        .thread_pool = opts.thread_pool,
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
            try self.thread_pool.spawn(worker, .{ self, &wg });
        }
    }
}

fn worker(self: *Server, wg: *WaitGroup) void {
    defer wg.finish();

    var client = self.stream_server.accept() catch |err| {
        std.log.err("accept error: {s}", .{@errorName(err)});
        return;
    };
    defer client.stream.close();

    var metadata = handshakeHandler(client.stream) catch |err| {
        log.scoped(.handshake).err("{s}", .{@errorName(err)});
        return;
    };
    log.info("received socks cmd: {s}", .{@tagName(metadata.command)});

    switch (metadata.command) {
        .connect => {
            var remote = connectHandler(
                self.allocator,
                client.stream,
                metadata,
            ) catch |err| {
                log.scoped(.connect).err("{s}", .{@errorName(err)});
                return;
            };
            defer remote.close();

            copyLoop(client.stream, remote) catch |err| {
                log.scoped(.connect).err("{s}", .{@errorName(err)});
                return;
            };
        },
        .associate => {
            log.scoped(.associate).err("UdpAssociateUnsupported", .{});
            return;
        },
        .bind => {
            log.scoped(.bind).err("BindCommandUnsupported", .{});
            return;
        },
    }
}

fn copyLoop(strm1: net.Stream, strm2: net.Stream) !void {
    const event = if (builtin.os.tag != .windows) blk: {
        break :blk os.POLL.IN;
    } else blk: {
        break :blk os.POLL.RDNORM | os.POLL.RDBAND;
    };

    var fds = [_]os.pollfd{
        .{ .fd = strm1.handle, .events = event, .revents = 0 },
        .{ .fd = strm2.handle, .events = event, .revents = 0 },
    };

    while (true) {
        if (builtin.os.tag != .windows) {
            _ = try os.poll(&fds, 60 * 15 * 1000);
        } else {
            _ = try poll(&fds, 60 * 15 * 1000);
        }

        var in = if (fds[0].revents & event > 0) strm1 else strm2;
        var out = if (std.meta.eql(in, strm2)) strm1 else strm2;
        var buf: [1024]u8 = undefined;

        var read_n = try in.reader().read(&buf);
        if (read_n <= 0) return;

        var sent_n: usize = 0;
        while (sent_n < read_n) {
            var sent = try out.writer().write(buf[sent_n..read_n]);
            sent_n += sent;
        }
    }
}

/// +----+-----+-------+------+----------+----------+
/// |VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
/// +----+-----+-------+------+----------+----------+
/// | 1  |  1  | X'00' |  1   | Variable |    2     |
/// +----+-----+-------+------+----------+----------+
fn connectHandler(
    allocator: mem.Allocator,
    stream: net.Stream,
    metadata: MetaData,
) !net.Stream {
    var remote: net.Stream = undefined;

    if (metadata.addrs.addr) |addr| {
        remote = try connectToAddress(stream, addr);
    }

    if (metadata.addrs.name) |name| {
        remote = try connectToDomain(
            allocator,
            stream,
            name,
            metadata.addrs.port.?,
        );
    }

    return remote;
}

fn connectToAddress(
    stream: net.Stream,
    addr: net.Address,
) !net.Stream {
    var remote = net.tcpConnectToAddress(addr) catch |err| {
        var fail = [_]u8{ 5, 4, 0, 1, 0, 0, 0, 0, 0, 0 };
        _ = try stream.writer().write(&fail);
        return err;
    };

    var success = [_]u8{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    _ = try stream.writer().write(&success);

    return remote;
}

fn connectToDomain(
    allocator: mem.Allocator,
    stream: net.Stream,
    name: []const u8,
    port: u16,
) !net.Stream {
    var remote = net.tcpConnectToHost(
        allocator,
        name,
        port,
    ) catch |err| {
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
fn handshakeHandler(stream: net.Stream) !MetaData {
    var version = try stream.reader().readByte();

    if (version != 5) {
        return error.SocksVersionUnsupported;
    }

    var nmethods = try stream.reader().readByte();

    var methods: [255]u8 = [_]u8{0} ** 255;
    _ = try stream.reader().read(methods[0..nmethods]);

    _ = try stream.writer().write(&[_]u8{ 5, 0x0 });

    var cmd_buf = try stream.reader().readBytesNoEof(3);

    log.info("handshake success, stream: {d}", .{stream.handle});
    return MetaData{
        .command = @intToEnum(Command, cmd_buf[1]),
        .addrs = try readAddress(stream),
    };
}

fn readAddress(stream: net.Stream) !AddressName {
    var addr_type = try stream.reader().readByte();

    switch (@intToEnum(AddressType, addr_type)) {
        .ipv4_addr => {
            var buf: [15]u8 = undefined;

            var addr_s = try stream.reader().readBytesNoEof(4);
            var port_s = try stream.reader().readBytesNoEof(2);

            var addr = try fmt.bufPrint(
                &buf,
                "{}.{}.{}.{}",
                .{ addr_s[0], addr_s[1], addr_s[2], addr_s[3] },
            );

            var port = @as(u16, port_s[0]) << 8 | port_s[1];
            return AddressName{
                .addr = try net.Address.parseIp(addr, port),
                .name = null,
                .port = null,
            };
        },
        .domain_name => {
            var buf: [253]u8 = undefined;
            var len = try stream.reader().readByte();
            var read_n = try stream.reader().read(buf[0..len]);
            var port_s = try stream.reader().readBytesNoEof(2);
            var port = @as(u16, port_s[0]) << 8 | port_s[1];

            std.debug.assert(read_n == len);

            return AddressName{
                .addr = null,
                .name = buf[0..len],
                .port = port,
            };
        },
        .ipv6_addr => {
            var buf: [39]u8 = undefined;

            var addr_s = try stream.reader().readBytesNoEof(16);
            var port_s = try stream.reader().readBytesNoEof(2);

            var addr = try fmt.bufPrint(
                &buf,
                "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:" ++
                    "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:" ++
                    "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:" ++
                    "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}",
                .{
                    addr_s[0],
                    addr_s[1],
                    addr_s[2],
                    addr_s[3],
                    addr_s[4],
                    addr_s[5],
                    addr_s[6],
                    addr_s[7],
                    addr_s[8],
                    addr_s[9],
                    addr_s[10],
                    addr_s[11],
                    addr_s[12],
                    addr_s[13],
                    addr_s[14],
                    addr_s[15],
                },
            );

            var port = @as(u16, port_s[0]) << 8 | port_s[1];
            return AddressName{
                .addr = try net.Address.parseIp(addr, port),
                .name = null,
                .port = null,
            };
        },
    }
}

fn poll(fds: []os.pollfd, timeout: i32) os.PollError!usize {
    while (true) {
        const fds_count = std.math.cast(os.nfds_t, fds.len) orelse
            return error.SystemResources;
        const rc = windows.ws2_32.WSAPoll(fds.ptr, fds_count, timeout);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAENOBUFS => return error.SystemResources,
                // TODO: handle more errors
                else => |err| return windows.unexpectedWSAError(err),
            }
        } else {
            return @intCast(usize, rc);
        }
        unreachable;
    }
}

const AddressType = enum(u8) {
    ipv4_addr = 0x01,
    domain_name = 0x03,
    ipv6_addr = 0x04,
};

const Command = enum(u8) {
    connect = 0x01,
    bind = 0x02,
    associate = 0x03,
};

const MetaData = struct {
    command: Command,
    addrs: AddressName,
};

const AddressName = struct {
    addr: ?net.Address,
    name: ?[]const u8,
    port: ?u16,
};

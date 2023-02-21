const std = @import("std");
const builtin = @import("builtin");
const IO = @import("io").IO;
const os = std.os;
const log = std.log;
const fmt = std.fmt;
const mem = std.mem;
const net = std.net;
const meta = std.meta;
const windows = std.os.windows;
const Server = @This();
const Context = Server;

io: IO,
client: net.Stream = undefined,
stream_server: net.StreamServer,
done: bool = false,

pub fn init(io: IO) Server {
    var stream_server = net.StreamServer.init(.{});

    return Server{
        .io = io,
        .stream_server = stream_server,
    };
}

pub fn deinit(self: *Server) void {
    self.stream_server.deinit();
}

pub fn startServe(self: *Server, listen_ip: []const u8, port: u16) !void {
    const listen_addr = try net.Address.parseIp(listen_ip, port);
    try self.stream_server.listen(listen_addr);

    while (true) {
        var completion: IO.Completion = undefined;
        self.io.accept(
            *Context,
            self,
            accept_callback,
            &completion,
            self.stream_server.sockfd.?,
        );
        while (!self.done) try self.io.tick();
        self.done = false;
    }
}

fn accept_callback(
    self: *Context,
    completion: *IO.Completion,
    result: IO.AcceptError!os.socket_t,
) void {
    _ = completion;
    self.client = net.Stream{
        .handle = result catch @panic("accept error"),
    };
<<<<<<< Updated upstream
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

            copyLoop(client.stream, remote) catch |err| {
                log.scoped(.connect).err("{s}", .{@errorName(err)});
                return;
            };
            log.info("copy loop ended", .{});
        },
        .associate => {},
        .bind => {
            log.scoped(.bind).err("BindCommandUnsupported", .{});
            return;
        },
    }
}

pub fn copyLoop(strm1: net.Stream, strm2: net.Stream) !void {
    const event = if (builtin.os.tag != .windows) blk: {
        break :blk os.POLL.IN;
    } else blk: {
        break :blk os.POLL.RDNORM & os.POLL.RDBAND;
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
=======
    defer self.client.close();
    self.done = true;
    log.info("accepted client: {}", .{self.client});
>>>>>>> Stashed changes
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
    address: DomainAddress,
};

const DomainAddress = struct {
    addr: ?net.Address,
    name: ?[]const u8,
};

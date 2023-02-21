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
buffer: [1024]u8 = undefined,
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
            onAccept,
            &completion,
            self.stream_server.sockfd.?,
        );
        while (!self.done) try self.io.tick();
        self.done = false;
    }
}

fn onAccept(
    self: *Context,
    completion: *IO.Completion,
    result: IO.AcceptError!os.socket_t,
) void {
    self.client = net.Stream{
        .handle = result catch @panic("accept error"),
    };
    log.info("accepted client: {}", .{self.client});
    self.recvVersion(completion);
}

fn recvVersion(self: *Context, completion: *IO.Completion) void {
    self.io.recv(
        *Context,
        self,
        onRecvVersion,
        completion,
        self.client.handle,
        self.buffer[0..1],
    );
}

fn onRecvVersion(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
    defer self.client.close();
    var len = result catch @panic("recv error");
    self.done = true;
    std.debug.assert(len == 1);
    log.info("socks version: {d}", .{self.buffer[0]});
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

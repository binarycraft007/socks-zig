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
    defer self.client.close();
    self.done = true;
    log.info("accepted client: {}", .{self.client});
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

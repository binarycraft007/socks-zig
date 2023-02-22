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
buffer: [2048]u8 = undefined,
addr: []const u8 = undefined,
port: u16 = undefined,
client: net.Stream = undefined,
remote: net.Stream = undefined,
command: Command = undefined,
addr_type: AddressType = undefined,
completion: IO.Completion = undefined,
stream_server: net.StreamServer,
done: bool = false,

const ListenOptions = struct {
    addr: []const u8,
    port: u16,
};

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

pub fn startServe(self: *Server, opts: ListenOptions) !void {
    const listen_addr = try net.Address.parseIp(
        opts.addr,
        opts.port,
    );
    try self.stream_server.listen(listen_addr);

    while (true) {
        self.io.accept(
            *Context,
            self,
            onAccept,
            &self.completion,
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

fn recvVersion(
    self: *Context,
    completion: *IO.Completion,
) void {
    self.io.recv(
        *Context,
        self,
        onRecvVersion,
        completion,
        self.client.handle,
        self.buffer[0..2],
    );
}

fn onRecvVersion(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = result catch @panic("recv error");
    log.info("socks version: {d}", .{self.buffer[0]});
    log.info("num of method: {d}", .{self.buffer[1]});
    self.recvMethods(completion, self.buffer[1]);
}

fn recvMethods(
    self: *Context,
    completion: *IO.Completion,
    num: usize,
) void {
    self.io.recv(
        *Context,
        self,
        onRecvMethods,
        completion,
        self.client.handle,
        self.buffer[0..num],
    );
}

fn onRecvMethods(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = result catch |err| @panic(@errorName(err));
    self.sendMethods(completion);
}

fn sendMethods(
    self: *Context,
    completion: *IO.Completion,
) void {
    self.io.send(
        *Context,
        self,
        onSendMethods,
        completion,
        self.client.handle,
        &[_]u8{ 5, 0 },
    );
}

fn onSendMethods(
    self: *Context,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = result catch @panic("send error");
    self.recvCommand(completion);
}

fn recvCommand(
    self: *Context,
    completion: *IO.Completion,
) void {
    self.io.recv(
        *Context,
        self,
        onRecvCommand,
        completion,
        self.client.handle,
        self.buffer[0..4],
    );
}

fn onRecvCommand(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = result catch @panic("recv error");
    self.command = @intToEnum(Command, self.buffer[1]);
    self.addr_type = @intToEnum(AddressType, self.buffer[3]);
    log.info("recv cmd: {s}", .{@tagName(self.command)});
    log.info("recv addr: {s}", .{@tagName(self.addr_type)});

    switch (self.command) {
        .connect => {
            switch (self.addr_type) {
                .ipv4_addr => {
                    self.recvIpv4Addr(completion);
                },
                .domain_name => {
                    // TODO
                },
                .ipv6_addr => {
                    // TODO
                },
            }
        },
        .associate => {
            // TODO
        },
        .bind => {
            // TODO
        },
    }
}

fn recvIpv4Addr(
    self: *Context,
    completion: *IO.Completion,
) void {
    self.io.recv(
        *Context,
        self,
        onRecvIpv4Addr,
        completion,
        self.client.handle,
        self.buffer[0..4],
    );
}

fn onRecvIpv4Addr(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = result catch @panic("recv error");
    self.addr = fmt.bufPrint(
        self.buffer[4 .. 4 + 15],
        "{}.{}.{}.{}",
        .{
            self.buffer[0],
            self.buffer[1],
            self.buffer[2],
            self.buffer[3],
        },
    ) catch |err| @panic(@errorName(err));
    self.recvPortNumber(completion);
}

fn recvPortNumber(
    self: *Context,
    completion: *IO.Completion,
) void {
    self.io.recv(
        *Context,
        self,
        onRecvPortNumber,
        completion,
        self.client.handle,
        self.buffer[0..2],
    );
}

fn onRecvPortNumber(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = result catch @panic("recv error");
    self.port = @as(u16, self.buffer[0]) <<
        8 | self.buffer[1];
    var address = net.Address.parseIp(
        self.addr,
        self.port,
    ) catch |err| @panic(@errorName(err));
    log.debug("addr: {s}", .{self.addr});
    log.debug("port: {d}", .{self.port});
    self.connectToRemote(completion, address);
}

fn connectToRemote(
    self: *Context,
    completion: *IO.Completion,
    address: net.Address,
) void {
    self.remote = net.Stream{
        .handle = os.socket(
            address.any.family,
            os.SOCK.STREAM,
            os.IPPROTO.TCP,
        ) catch |err| @panic(@errorName(err)),
    };

    log.info("connect to: {}", .{address});
    self.io.connect(
        *Context,
        self,
        onConnectToRemote,
        completion,
        self.remote.handle,
        address,
    );
}

fn onConnectToRemote(
    self: *Context,
    completion: *IO.Completion,
    result: IO.ConnectError!void,
) void {
    _ = result catch |err| @panic(@errorName(err));
    self.sendReplyMsg(completion);
}

fn sendReplyMsg(
    self: *Context,
    completion: *IO.Completion,
) void {
    self.io.send(
        *Context,
        self,
        onSendReplyMsg,
        completion,
        self.client.handle,
        &[_]u8{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 },
    );
}

fn onSendReplyMsg(
    self: *Context,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = result catch @panic("recv error");
    self.recvClientReq(completion);
}

fn recvClientReq(
    self: *Context,
    completion: *IO.Completion,
) void {
    self.io.recv(
        *Context,
        self,
        onRecvClientReq,
        completion,
        self.client.handle,
        &self.buffer,
    );
}

fn onRecvClientReq(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    var len = result catch @panic("recv error");
    log.info("recv client len: {d}", .{len});
    log.info("method: {s}", .{self.buffer[0..4]});
    self.sendReqRemote(completion, len);
}

fn sendReqRemote(
    self: *Context,
    completion: *IO.Completion,
    msg_len: usize,
) void {
    self.io.send(
        *Context,
        self,
        onSendReqRemote,
        completion,
        self.remote.handle,
        self.buffer[0..msg_len],
    );
}

fn onSendReqRemote(
    self: *Context,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    var len = result catch @panic("recv error");
    log.info("send remote len: {d}", .{len});
    self.recvRemoteRsp(completion);
}

fn recvRemoteRsp(
    self: *Context,
    completion: *IO.Completion,
) void {
    self.io.recv(
        *Context,
        self,
        onRecvRemoteRsp,
        completion,
        self.remote.handle,
        &self.buffer,
    );
}

fn onRecvRemoteRsp(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    var len = result catch @panic("recv error");
    log.info("recv remote len: {d}", .{len});
    self.sendRspClient(completion, len);
}

fn sendRspClient(
    self: *Context,
    completion: *IO.Completion,
    msg_len: usize,
) void {
    self.io.send(
        *Context,
        self,
        onSendRspClient,
        completion,
        self.client.handle,
        self.buffer[0..msg_len],
    );
}

fn onSendRspClient(
    self: *Context,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = completion;
    defer self.client.close();
    defer self.remote.close();
    defer self.done = true;
    var len = result catch @panic("recv error");
    log.info("recv remote len: {d}", .{len});
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

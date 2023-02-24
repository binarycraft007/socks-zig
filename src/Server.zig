const std = @import("std");
const RingBuffer = std.RingBuffer;
const builtin = @import("builtin");
const IO = @import("io").IO;
const os = std.os;
const log = std.log;
const fmt = std.fmt;
const mem = std.mem;
const net = std.net;
const meta = std.meta;
const http = std.http;
const windows = std.os.windows;
const Server = @This();
const Context = Server;

io: IO,
allocator: mem.Allocator,
client_fd: os.socket_t = undefined,
accp_compl: IO.Completion = undefined,
server_fd: os.socket_t = undefined,

const ListenOptions = struct {
    addr: []const u8,
    port: u16,
};

pub fn init(allocator: mem.Allocator, io: IO) Server {
    return Server{ .io = io, .allocator = allocator };
}

pub fn deinit(self: *Server) void {
    os.closeSocket(self.server_fd);
}

pub fn startServe(self: *Server, opts: ListenOptions) !void {
    // Setup the server socket
    self.server_fd = try self.io.open_socket(
        os.AF.INET,
        os.SOCK.STREAM,
        os.IPPROTO.TCP,
    );
    try os.setsockopt(
        self.server_fd,
        os.SOL.SOCKET,
        os.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    const address = try std.net.Address.parseIp4(
        opts.addr,
        opts.port,
    );

    const sock_len = address.getOsSockLen();
    try os.bind(self.server_fd, &address.any, sock_len);
    try os.listen(self.server_fd, 1);

    self.acceptConnection();
    while (true) try self.io.tick();
}

fn acceptConnection(self: *Context) void {
    self.io.accept(
        *Context,
        self,
        onAcceptConnection,
        &self.accp_compl,
        self.server_fd,
    );
}

fn onAcceptConnection(
    self: *Context,
    completion: *IO.Completion,
    result: IO.AcceptError!os.socket_t,
) void {
    _ = completion;
    self.client_fd = result catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };

    log.info("accepted client: {}", .{self.client_fd});

    var handshake = HandshakeSession.init(.{
        .gpa = self.allocator,
        .io = self.io,
        .client_fd = self.client_fd,
    }) catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };
    handshake.recvFromClient();
    self.acceptConnection();
}

const HandshakeSession = struct {
    const Self = @This();

    const SessionState = enum {
        greet_start,
        completed,
        need_more,
        failed,
    };

    const SessionInitOptions = struct {
        gpa: mem.Allocator,
        io: IO,
        client_fd: os.socket_t,
    };

    io: IO,
    gpa: mem.Allocator,
    state: SessionState,
    client_fd: os.socket_t,
    remote_fd: os.socket_t = undefined,
    recv_compl: IO.Completion = undefined,
    send_compl: IO.Completion = undefined,
    conn_compl: IO.Completion = undefined,
    buffer: [1024]u8 = undefined,
    read_buf: RingBuffer,
    write_buf: RingBuffer,

    pub fn init(opts: SessionInitOptions) !Self {
        return Self{
            .gpa = opts.gpa,
            .io = opts.io,
            .state = .greet_start,
            .client_fd = opts.client_fd,
            .read_buf = try RingBuffer.init(
                opts.gpa,
                1 << 14,
            ),
            .write_buf = try RingBuffer.init(
                opts.gpa,
                1 << 14,
            ),
        };
    }

    pub fn recvFromClient(self: *Self) void {
        self.io.recv(
            *Self,
            self,
            onRecvFromClient,
            &self.recv_compl,
            self.client_fd,
            &self.buffer,
        );
    }

    pub fn onRecvFromClient(
        self: *Self,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        _ = completion;
        var len = result catch |err| {
            log.err("{s}", .{@errorName(err)});
            self.deinit();
            return;
        };
        var read = self.buffer[0..len];
        self.read_buf.writeSlice(read) catch |err| {
            log.err("{s}", .{@errorName(err)});
            self.deinit();
            return;
        };
        switch (self.state) {
            .greet_start => {
                self.state = self.Greet();
            },
            .need_more => {},
            .failed => {},
            .completed => {},
        }
    }

    pub fn Greet(self: *Self) SessionState {
        var needed_len = self.read_buf.data[1] + 2;
        if (self.read_buf.read_index < needed_len) {
            return .need_more;
        }

        var version = self.read_buf.data[0];

        if (version != 0x05) {}

        var nmethods = self.read_buf.data[1];
        var methods = self.read_buf.data[2..nmethods];

        var method_supported = false;
        for (methods) |method| {
            if (method == 0x00) {
                method_supported = true;
                break;
            }
        }
        return .completed;
    }

    pub fn Error(self: *Self) SessionState {
        _ = self;
        return .failed;
    }

    pub fn deinit(self: *Self) void {
        os.closeSocket(self.client_fd);
        self.read_buf.deinit(self.gpa);
        self.write_buf.deinit(self.gpa);
    }
};

//fn recvVersion(
//    self: *Context,
//    completion: *IO.Completion,
//) void {
//    log.info("read version", .{});
//    self.io.recv(
//        *Context,
//        self,
//        onRecvVersion,
//        completion,
//        self.client_fd,
//        self.buffer[0..2],
//    );
//}
//
//fn onRecvVersion(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.RecvError!usize,
//) void {
//    _ = completion;
//    _ = result catch |err| @panic(@errorName(err));
//    log.info("socks version: {d}", .{self.buffer[0]});
//    log.info("num of method: {d}", .{self.buffer[1]});
//    self.recvMethods(
//        &self.recv_compl,
//        self.buffer[1],
//    );
//}
//
//fn recvMethods(
//    self: *Context,
//    completion: *IO.Completion,
//    num: usize,
//) void {
//    self.io.recv(
//        *Context,
//        self,
//        onRecvMethods,
//        completion,
//        self.client_fd,
//        self.buffer[0..num],
//    );
//}
//
//fn onRecvMethods(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.RecvError!usize,
//) void {
//    _ = completion;
//    _ = result catch |err| @panic(@errorName(err));
//    self.sendMethods(
//        &self.send_compl,
//    );
//}
//
//fn sendMethods(
//    self: *Context,
//    completion: *IO.Completion,
//) void {
//    self.io.send(
//        *Context,
//        self,
//        onSendMethods,
//        completion,
//        self.client_fd,
//        &[_]u8{ 5, 0 },
//    );
//}
//
//fn onSendMethods(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.SendError!usize,
//) void {
//    _ = completion;
//    _ = result catch @panic("send error");
//
//    self.recvCommand(&self.recv_compl);
//}
//
//fn recvCommand(
//    self: *Context,
//    completion: *IO.Completion,
//) void {
//    self.io.recv(
//        *Context,
//        self,
//        onRecvCommand,
//        completion,
//        self.client_fd,
//        self.buffer[0..4],
//    );
//}
//
//fn onRecvCommand(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.RecvError!usize,
//) void {
//    _ = completion;
//    _ = result catch @panic("recv error");
//    self.command = @intToEnum(Command, self.buffer[1]);
//    self.addr_type = @intToEnum(AddressType, self.buffer[3]);
//    log.info("recv cmd: {s}", .{@tagName(self.command)});
//    log.info("recv addr: {s}", .{@tagName(self.addr_type)});
//
//    switch (self.command) {
//        .connect => {
//            switch (self.addr_type) {
//                .ipv4_addr => {
//                    self.recvIpv4Addr(&self.recv_compl);
//                },
//                .domain_name => {
//                    // TODO
//                },
//                .ipv6_addr => {
//                    // TODO
//                },
//            }
//        },
//        .associate => {
//            // TODO
//        },
//        .bind => {
//            // TODO
//        },
//    }
//}
//
//fn recvIpv4Addr(
//    self: *Context,
//    completion: *IO.Completion,
//) void {
//    self.io.recv(
//        *Context,
//        self,
//        onRecvIpv4Addr,
//        completion,
//        self.client_fd,
//        self.buffer[0..4],
//    );
//}
//
//fn onRecvIpv4Addr(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.RecvError!usize,
//) void {
//    _ = completion;
//    _ = result catch @panic("recv error");
//    self.addr = fmt.bufPrint(
//        self.buffer[4 .. 4 + 15],
//        "{}.{}.{}.{}",
//        .{
//            self.buffer[0],
//            self.buffer[1],
//            self.buffer[2],
//            self.buffer[3],
//        },
//    ) catch |err| @panic(@errorName(err));
//    self.recvPortNumber(&self.recv_compl);
//}
//
//fn recvPortNumber(
//    self: *Context,
//    completion: *IO.Completion,
//) void {
//    self.io.recv(
//        *Context,
//        self,
//        onRecvPortNumber,
//        completion,
//        self.client_fd,
//        self.buffer[0..2],
//    );
//}
//
//fn onRecvPortNumber(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.RecvError!usize,
//) void {
//    _ = completion;
//    _ = result catch @panic("recv error");
//    self.port = @as(u16, self.buffer[0]) <<
//        8 | self.buffer[1];
//    var address = net.Address.parseIp(
//        self.addr,
//        self.port,
//    ) catch |err| @panic(@errorName(err));
//    log.debug("addr: {s}", .{self.addr});
//    log.debug("port: {d}", .{self.port});
//    self.connectToRemote(&self.conn_compl, address);
//}
//
//fn connectToRemote(
//    self: *Context,
//    completion: *IO.Completion,
//    address: net.Address,
//) void {
//    self.remote_fd = os.socket(
//        address.any.family,
//        os.SOCK.STREAM,
//        os.IPPROTO.TCP,
//    ) catch |err| @panic(@errorName(err));
//
//    log.info("connect to: {}", .{address});
//    self.io.connect(
//        *Context,
//        self,
//        onConnectToRemote,
//        completion,
//        self.remote_fd,
//        address,
//    );
//}
//
//fn onConnectToRemote(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.ConnectError!void,
//) void {
//    _ = completion;
//    _ = result catch |err| @panic(@errorName(err));
//    self.sendReplyMsg(&self.send_compl);
//}
//
//fn sendReplyMsg(
//    self: *Context,
//    completion: *IO.Completion,
//) void {
//    self.io.send(
//        *Context,
//        self,
//        onSendReplyMsg,
//        completion,
//        self.client_fd,
//        &[_]u8{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 },
//    );
//}
//
//fn onSendReplyMsg(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.SendError!usize,
//) void {
//    _ = completion;
//    _ = result catch @panic("recv error");
//
//    os.closeSocket(self.client_fd);
//    os.closeSocket(self.remote_fd);
//    //self.recvClientReq(
//    //    self.compl_list.popFirst().?.data,
//    //);
//}
//
//fn recvClientReq(
//    self: *Context,
//    completion: *IO.Completion,
//) void {
//    _ = completion;
//    self.io.recv(
//        *Context,
//        self,
//        onRecvClientReq,
//        self.compl_list.popFirst().?.data,
//        self.client_fd,
//        &self.buffer,
//    );
//}
//
//fn onRecvClientReq(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.RecvError!usize,
//) void {
//    _ = completion;
//    var len = result catch @panic("recv error");
//    log.info("recv client len: {d}", .{len});
//    self.sendReqRemote(
//        self.compl_list.popFirst().?.data,
//        len,
//    );
//
//    if (len != 0) {
//        self.recvClientReq(
//            self.compl_list.popFirst().?.data,
//        );
//    }
//}
//
//fn sendReqRemote(
//    self: *Context,
//    completion: *IO.Completion,
//    msg_len: usize,
//) void {
//    _ = completion;
//    self.io.send(
//        *Context,
//        self,
//        onSendReqRemote,
//        &self.compls[22],
//        self.remote.handle,
//        self.buffer[0..msg_len],
//    );
//}
//
//fn onSendReqRemote(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.SendError!usize,
//) void {
//    _ = completion;
//    var len = result catch @panic("recv error");
//    log.info("send remote len: {d}", .{len});
//    self.recvRemoteRsp(
//        self.compl_list.popFirst().?.data,
//    );
//}
//
//fn recvRemoteRsp(
//    self: *Context,
//    completion: *IO.Completion,
//) void {
//    _ = completion;
//    self.io.recv(
//        *Context,
//        self,
//        onRecvRemoteRsp,
//        self.compl_list.popFirst().?.data,
//        self.remote.handle,
//        &self.buffer,
//    );
//}
//
//fn onRecvRemoteRsp(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.RecvError!usize,
//) void {
//    _ = completion;
//    var len = result catch @panic("recv error");
//    log.info("recv remote len: {d}", .{len});
//    self.recv_len += len;
//    self.sendRspClient(
//        self.compl_list.popFirst().?.data,
//        len,
//    );
//
//    if (len != 0) {
//        self.recvRemoteRsp(
//            self.compl_list.popFirst().?.data,
//        );
//    }
//}
//
//fn sendRspClient(
//    self: *Context,
//    completion: *IO.Completion,
//    msg_len: usize,
//) void {
//    _ = completion;
//    self.io.send(
//        *Context,
//        self,
//        onSendRspClient,
//        self.compl_list.popFirst().?.data,
//        self.client.handle,
//        self.buffer[0..msg_len],
//    );
//}
//
//fn onSendRspClient(
//    self: *Context,
//    completion: *IO.Completion,
//    result: IO.SendError!usize,
//) void {
//    _ = completion;
//    var len = result catch |err| @panic(@errorName(err));
//    self.send_len += len;
//    log.info("send client len: {d}", .{len});
//}

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

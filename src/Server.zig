const std = @import("std");
const SinglyLinkedList = std.SinglyLinkedList;
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

const ComplList = SinglyLinkedList(*IO.Completion);

io: IO,
buffer: [8192]u8 = undefined,
addr: []const u8 = undefined,
port: u16 = undefined,
client: net.Stream = undefined,
remote: net.Stream = undefined,
command: Command = undefined,
addr_type: AddressType = undefined,
compls: [100]IO.Completion = undefined,
compl_list: ComplList = undefined,
recv_len: usize = 0,
send_len: usize = 0,
stream_server: net.StreamServer,
done: bool = false,

const ListenOptions = struct {
    addr: []const u8,
    port: u16,
};

pub fn init(io: IO) Server {
    return Server{
        .io = io,
        .stream_server = net.StreamServer.init(.{}),
    };
}

pub fn deinit(self: *Server) void {
    //self.client.close();
    //self.remote.close();
    self.stream_server.deinit();
}

pub fn startServe(self: *Server, opts: ListenOptions) !void {
    inline for (&self.compls) |*compl| {
        self.compl_list.prepend(&ComplList.Node{ .data = compl });
    }

    const listen_addr = try net.Address.parseIp(opts.addr, opts.port);
    try self.stream_server.listen(listen_addr);

    self.acceptConnection(self.compl_list.popFirst().?.data);
    while (true) try self.io.tick();
}

fn acceptConnection(
    self: *Context,
    completion: *IO.Completion,
) void {
    _ = completion;
    self.io.accept(
        *Context,
        self,
        onAcceptConnection,
        self.compl_list.popFirst().?.data,
        self.stream_server.sockfd.?,
    );
}

fn onAcceptConnection(
    self: *Context,
    completion: *IO.Completion,
    result: IO.AcceptError!os.socket_t,
) void {
    _ = completion;
    self.client = net.Stream{
        .handle = result catch |err| switch (err) {
            error.FileDescriptorInvalid => return,
            else => {
                log.err("{s}", .{@errorName(err)});
                return;
            },
        },
    };

    log.info("accepted client: {}", .{self.client});

    self.recvVersion(self.compl_list.popFirst().?.data);
    self.acceptConnection(
        self.compl_list.popFirst().?.data,
    );
}

fn recvVersion(
    self: *Context,
    completion: *IO.Completion,
) void {
    _ = completion;
    self.io.recv(
        *Context,
        self,
        onRecvVersion,
        self.compl_list.popFirst().?.data,
        self.client.handle,
        self.buffer[0..2],
    );
}

fn onRecvVersion(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
    _ = result catch |err| @panic(@errorName(err));
    log.info("socks version: {d}", .{self.buffer[0]});
    log.info("num of method: {d}", .{self.buffer[1]});
    self.recvMethods(
        self.compl_list.popFirst().?.data,
        self.buffer[1],
    );
}

fn recvMethods(
    self: *Context,
    completion: *IO.Completion,
    num: usize,
) void {
    _ = completion;
    self.io.recv(
        *Context,
        self,
        onRecvMethods,
        self.compl_list.popFirst().?.data,
        self.client.handle,
        self.buffer[0..num],
    );
}

fn onRecvMethods(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
    _ = result catch |err| @panic(@errorName(err));
    self.sendMethods(
        self.compl_list.popFirst().?.data,
    );
}

fn sendMethods(
    self: *Context,
    completion: *IO.Completion,
) void {
    _ = completion;
    self.io.send(
        *Context,
        self,
        onSendMethods,
        self.compl_list.popFirst().?.data,
        self.client.handle,
        &[_]u8{ 5, 0 },
    );
}

fn onSendMethods(
    self: *Context,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = completion;
    _ = result catch @panic("send error");
    self.recvCommand(
        self.compl_list.popFirst().?.data,
    );
}

fn recvCommand(
    self: *Context,
    completion: *IO.Completion,
) void {
    _ = completion;
    self.io.recv(
        *Context,
        self,
        onRecvCommand,
        self.compl_list.popFirst().?.data,
        self.client.handle,
        self.buffer[0..4],
    );
}

fn onRecvCommand(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
    _ = result catch @panic("recv error");
    self.command = @intToEnum(Command, self.buffer[1]);
    self.addr_type = @intToEnum(AddressType, self.buffer[3]);
    log.info("recv cmd: {s}", .{@tagName(self.command)});
    log.info("recv addr: {s}", .{@tagName(self.addr_type)});

    switch (self.command) {
        .connect => {
            switch (self.addr_type) {
                .ipv4_addr => {
                    self.recvIpv4Addr(self.compl_list.popFirst().?.data);
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
    _ = completion;
    self.io.recv(
        *Context,
        self,
        onRecvIpv4Addr,
        self.compl_list.popFirst().?.data,
        self.client.handle,
        self.buffer[0..4],
    );
}

fn onRecvIpv4Addr(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
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
    self.recvPortNumber(
        self.compl_list.popFirst().?.data,
    );
}

fn recvPortNumber(
    self: *Context,
    completion: *IO.Completion,
) void {
    _ = completion;
    self.io.recv(
        *Context,
        self,
        onRecvPortNumber,
        self.compl_list.popFirst().?.data,
        self.client.handle,
        self.buffer[0..2],
    );
}

fn onRecvPortNumber(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
    _ = result catch @panic("recv error");
    self.port = @as(u16, self.buffer[0]) <<
        8 | self.buffer[1];
    var address = net.Address.parseIp(
        self.addr,
        self.port,
    ) catch |err| @panic(@errorName(err));
    log.debug("addr: {s}", .{self.addr});
    log.debug("port: {d}", .{self.port});
    self.connectToRemote(
        self.compl_list.popFirst().?.data,
        address,
    );
}

fn connectToRemote(
    self: *Context,
    completion: *IO.Completion,
    address: net.Address,
) void {
    _ = completion;
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
        self.compl_list.popFirst().?.data,
        self.remote.handle,
        address,
    );
}

fn onConnectToRemote(
    self: *Context,
    completion: *IO.Completion,
    result: IO.ConnectError!void,
) void {
    _ = completion;
    _ = result catch |err| @panic(@errorName(err));
    self.sendReplyMsg(
        self.compl_list.popFirst().?.data,
    );
}

fn sendReplyMsg(
    self: *Context,
    completion: *IO.Completion,
) void {
    _ = completion;
    self.io.send(
        *Context,
        self,
        onSendReplyMsg,
        self.compl_list.popFirst().?.data,
        self.client.handle,
        &[_]u8{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 },
    );
}

fn onSendReplyMsg(
    self: *Context,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = completion;
    _ = result catch @panic("recv error");
    self.recvClientReq(
        self.compl_list.popFirst().?.data,
    );
}

fn recvClientReq(
    self: *Context,
    completion: *IO.Completion,
) void {
    _ = completion;
    self.io.recv(
        *Context,
        self,
        onRecvClientReq,
        self.compl_list.popFirst().?.data,
        self.client.handle,
        &self.buffer,
    );
}

fn onRecvClientReq(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
    var len = result catch @panic("recv error");
    log.info("recv client len: {d}", .{len});
    self.sendReqRemote(
        self.compl_list.popFirst().?.data,
        len,
    );
}

fn sendReqRemote(
    self: *Context,
    completion: *IO.Completion,
    msg_len: usize,
) void {
    _ = completion;
    self.io.send(
        *Context,
        self,
        onSendReqRemote,
        &self.compls[22],
        self.remote.handle,
        self.buffer[0..msg_len],
    );
}

fn onSendReqRemote(
    self: *Context,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = completion;
    var len = result catch @panic("recv error");
    log.info("send remote len: {d}", .{len});
    self.recvRemoteRsp(
        self.compl_list.popFirst().?.data,
    );
}

fn recvRemoteRsp(
    self: *Context,
    completion: *IO.Completion,
) void {
    _ = completion;
    self.io.recv(
        *Context,
        self,
        onRecvRemoteRsp,
        self.compl_list.popFirst().?.data,
        self.remote.handle,
        &self.buffer,
    );
}

fn onRecvRemoteRsp(
    self: *Context,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
    var len = result catch @panic("recv error");
    log.info("recv remote len: {d}", .{len});
    self.recv_len += len;
    self.sendRspClient(
        self.compl_list.popFirst().?.data,
        len,
    );

    if (len != 0) {
        self.recvRemoteRsp(
            self.compl_list.popFirst().?.data,
        );
    }
}

fn sendRspClient(
    self: *Context,
    completion: *IO.Completion,
    msg_len: usize,
) void {
    _ = completion;
    self.io.send(
        *Context,
        self,
        onSendRspClient,
        self.compl_list.popFirst().?.data,
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
    var len = result catch |err| @panic(@errorName(err));
    self.send_len += len;
    log.info("send client len: {d}", .{len});
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

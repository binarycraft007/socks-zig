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
const assert = std.debug.assert;
const windows = std.os.windows;
const Server = @This();
const Context = Server;

const buf_size = 1024;

io: IO,
gpa: mem.Allocator,
client_fd: os.socket_t = undefined,
accp_compl: IO.Completion = undefined,
server_fd: os.socket_t = undefined,
handshake: HandshakeSession = undefined,
tunnel: TunnelSession = undefined,

const ListenOptions = struct {
    addr: []const u8,
    port: u16,
};

pub fn init(allocator: mem.Allocator, io: IO) Server {
    return Server{ .io = io, .gpa = allocator };
}

pub fn deinit(self: *Server) void {
    os.closeSocket(self.server_fd);
}

pub fn startServe(self: *Server, opts: ListenOptions) !void {
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

    self.handshake = HandshakeSession.init(.{
        .parent = self,
    }) catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };

    self.handshake.recvFromClient();
    self.acceptConnection();
}

const HandshakeSession = struct {
    const Self = @This();

    const State = enum {
        completed,
        need_more,
        closed,
        err_state,
    };

    const InitOptions = struct {
        parent: *Context,
    };

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

    parent: *Context,
    state_fn: *const fn (self: *Self) State,
    remote_fd: os.socket_t = undefined,
    recv_compl: IO.Completion = undefined,
    send_compl: IO.Completion = undefined,
    conn_compl: IO.Completion = undefined,
    buffer: [buf_size]u8 = undefined,
    addr_buf: RingBuffer = undefined,
    read_buf: RingBuffer = undefined,
    write_buf: RingBuffer = undefined,

    pub fn init(opts: InitOptions) !Self {
        return Self{
            .state_fn = onGreet,
            .addr_buf = try RingBuffer.init(
                opts.parent.gpa,
                buf_size,
            ),
            .read_buf = try RingBuffer.init(
                opts.parent.gpa,
                buf_size,
            ),
            .write_buf = try RingBuffer.init(
                opts.parent.gpa,
                buf_size,
            ),
            .parent = opts.parent,
        };
    }

    pub fn recvFromClient(self: *Self) void {
        self.parent.io.recv(
            *Context,
            self.parent,
            onRecvFromClient,
            &self.recv_compl,
            self.parent.client_fd,
            &self.buffer,
        );
    }

    pub fn onRecvFromClient(
        ctx: *Context,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        _ = completion;
        log.info("recv from client", .{});
        var len = result catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        };

        var ses = &ctx.handshake;
        var read = ses.buffer[0..len];
        ses.read_buf.writeSlice(read) catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        };

        switch (ses.state_fn(ses)) {
            .need_more => {
                if (ses.write_buf.isEmpty())
                    ses.recvFromClient();
            },
            .closed => {}, // do nothing,
            .completed => {
                if (!ses.read_buf.isEmpty())
                    ses.deinit();
            },
            .err_state => ses.deinit(),
        }
    }

    pub fn sendToClient(self: *Self) void {
        self.parent.io.send(
            *Context,
            self.parent,
            onSendToClient,
            &self.send_compl,
            self.parent.client_fd,
            self.write_buf.sliceLast(
                self.write_buf.len(),
            ).first,
        );
    }

    pub fn onSendToClient(
        ctx: *Context,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        _ = completion;
        log.info("send to client", .{});
        var len = result catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        };

        var ses = &ctx.handshake;

        for (0..len) |_|
            _ = ses.write_buf.read().?;

        if (ses.write_buf.isEmpty()) {
            ses.recvFromClient();
        } else {
            ses.sendToClient();
        }
    }

    pub fn connectToAddress(self: *Self) void {
        const size = @sizeOf(net.Address);
        var bytes: [size]u8 = undefined;

        inline for (0..size) |i| {
            bytes[i] = self.addr_buf.read().?;
        }

        const address = @bitCast(
            net.Address,
            bytes,
        );

        self.remote_fd = self.parent.io.open_socket(
            address.any.family,
            os.SOCK.STREAM,
            os.IPPROTO.TCP,
        ) catch |err| {
            log.err(
                "{s}",
                .{@errorName(err)},
            );
            return;
        };

        self.parent.io.connect(
            *Context,
            self.parent,
            onConnectToAddress,
            &self.conn_compl,
            self.remote_fd,
            address,
        );
    }

    pub fn onConnectToAddress(
        ctx: *Context,
        completion: *IO.Completion,
        result: IO.ConnectError!void,
    ) void {
        _ = completion;
        var ses = &ctx.handshake;

        log.info("connect to addr", .{});
        _ = result catch |err| switch (err) {
            error.ConnectionRefused => {
                if (!ses.addr_buf.isEmpty()) {
                    ses.connectToAddress();
                } else {
                    return;
                }
            },
            else => {
                log.err("{s}", .{@errorName(err)});
                return;
            },
        };

        var is_writing = !ses.write_buf.isEmpty();
        var reply = [_]u8{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
        ses.write_buf.writeSlice(&reply) catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        };
        if (!is_writing) ses.sendToClient();
    }

    pub fn onGreet(self: *Self) State {
        log.info("socks start greeting", .{});
        if (self.read_buf.len() < 2) {
            return .need_more;
        }

        var version = self.read_buf.read().?;
        var nmethods = self.read_buf.read().?;

        log.info("socks version: {d}", .{version});
        if (version != 0x05) {
            log.err("only version 5 is supported", .{});
            return .completed;
        }

        if (self.read_buf.len() < nmethods)
            return .need_more;

        var method_supported = false;
        for (0..nmethods) |_| {
            if (self.read_buf.read().? == 0x00) {
                method_supported = true;
                log.info("selected auth: 0x00", .{});
            }
        }

        if (!method_supported) {
            log.err("no auth method is supported", .{});
            return .completed;
        }

        var is_writing = !self.write_buf.isEmpty();
        var reply = [_]u8{ version, 0x00 };
        self.write_buf.writeSlice(&reply) catch |err| {
            log.err("{s}", .{@errorName(err)});
            return .completed;
        };

        if (!is_writing) self.sendToClient();
        log.info("handshake auth success", .{});

        self.state_fn = onRequest;

        return .completed;
    }

    pub fn onRequest(self: *Self) State {
        if (self.read_buf.len() < 4)
            return .need_more;

        if (self.read_buf.read().? != 0x05) {
            log.err("protocol not supported", .{});
            return .closed;
        }

        var command = self.read_buf.read().?;
        switch (@intToEnum(Command, command)) {
            .connect => {},
            else => |cmd| {
                log.err(
                    "command: {s} not supported",
                    .{@tagName(cmd)},
                );
                return .closed;
            },
        }

        assert(self.read_buf.read().? == 0); // reserved

        const addr_type = self.read_buf.read().?;
        switch (@intToEnum(AddressType, addr_type)) {
            .ipv4_addr => {
                if (self.read_buf.len() < 6)
                    return .need_more;

                var buf: [15]u8 = undefined;
                var addr = fmt.bufPrint(
                    &buf,
                    "{}.{}.{}.{}",
                    .{
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                    },
                ) catch unreachable;

                var port_l: u16 = self.read_buf.read().?;
                var port_h: u16 = self.read_buf.read().?;
                var port = port_l << 8 | port_h;
                log.info("addr: {s}", .{addr});
                log.info("port: {d}", .{port});

                var address = net.Address.parseIp(
                    addr,
                    port,
                ) catch |err| {
                    log.err("{s}", .{@errorName(err)});
                    return .closed;
                };

                self.addr_buf.writeSlice(
                    mem.asBytes(&address),
                ) catch |err| {
                    log.err("{s}", .{@errorName(err)});
                    return .closed;
                };
                self.state_fn = onFinish;
                self.connectToAddress();
            },
            .domain_name => {
                var buf: [253]u8 = undefined;
                var name_len = self.read_buf.read().?;

                if (self.read_buf.len() < name_len)
                    return .need_more;

                for (0..name_len) |i| {
                    buf[i] = self.read_buf.read().?;
                }

                var name = buf[0..name_len];
                var port_l: u16 = self.read_buf.read().?;
                var port_h: u16 = self.read_buf.read().?;
                var port = port_l << 8 | port_h;

                log.info("name: {s}", .{name});
                log.info("port: {d}", .{port});

                const list = net.getAddressList(
                    self.parent.gpa,
                    name,
                    port,
                ) catch |err| {
                    log.err("{s}", .{@errorName(err)});
                    return .closed;
                };
                defer list.deinit();

                if (list.addrs.len == 0) {
                    log.err("UnknownHostName", .{});
                    return .closed;
                }

                for (list.addrs) |addr| {
                    self.addr_buf.writeSlice(
                        mem.asBytes(&addr),
                    ) catch |err| {
                        log.err("{s}", .{@errorName(err)});
                        return .closed;
                    };
                }
                self.state_fn = onFinish;
                self.connectToAddress();
            },
            .ipv6_addr => {
                var buf: [39]u8 = undefined;

                if (self.read_buf.len() < 18)
                    return .need_more;

                var addr = fmt.bufPrint(
                    &buf,
                    "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:" ++
                        "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:" ++
                        "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:" ++
                        "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}",
                    .{
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                        self.read_buf.read().?,
                    },
                ) catch unreachable;

                var port_l: u16 = self.read_buf.read().?;
                var port_h: u16 = self.read_buf.read().?;
                var port = port_l << 8 | port_h;
                log.info("addr: {s}", .{addr});
                log.info("port: {d}", .{port});

                var address = net.Address.parseIp(
                    addr,
                    port,
                ) catch |err| {
                    log.err("{s}", .{@errorName(err)});
                    return .closed;
                };
                self.addr_buf.writeSlice(
                    mem.asBytes(&address),
                ) catch |err| {
                    log.err("{s}", .{@errorName(err)});
                    return .closed;
                };
                self.state_fn = onFinish;
                self.connectToAddress();
            },
        }

        return .closed;
    }

    pub fn onFinish(self: *Self) State {
        const parent = self.parent;

        parent.tunnel = TunnelSession.init(
            .{
                .parent = self.parent,
                .client_buf = self.read_buf,
                .remote_buf = self.write_buf,
            },
        ) catch |err| {
            log.err("{s}", .{@errorName(err)});
            return .closed;
        };
        self.deinit();
        //defer parent.tunnel.deinit();

        parent.tunnel.client = Connection.init(.{
            .socket = parent.client_fd,
            .owner = &parent.tunnel,
            .other = &parent.tunnel.remote,
            .is_client = true,
            .readable = true,
            .writable = true,
        }) catch |err| {
            log.err("{s}", .{@errorName(err)});
            return .closed;
        };

        parent.tunnel.remote = Connection.init(.{
            .socket = self.remote_fd,
            .owner = &parent.tunnel,
            .other = &parent.tunnel.client,
            .is_client = false,
            .readable = true,
            .writable = true,
        }) catch |err| {
            log.err("{s}", .{@errorName(err)});
            return .closed;
        };

        parent.tunnel.start();

        return .closed;
    }

    pub fn deinit(self: *Self) void {
        self.read_buf.deinit(self.parent.gpa);
        self.write_buf.deinit(self.parent.gpa);
    }
};

const Connection = struct {
    const Self = @This();

    socket: os.socket_t,
    owner: *TunnelSession,
    other: *Connection,
    is_client: bool,
    readable: bool,
    writable: bool,
    write_buf: RingBuffer,
    read_buf: RingBuffer,
    recving: bool = false,
    sending: bool = false,
    buffer: [buf_size]u8 = undefined,

    const InitOptions = struct {
        socket: os.socket_t,
        owner: *TunnelSession,
        other: *Connection,
        is_client: bool,
        readable: bool,
        writable: bool,
    };

    pub fn init(opts: InitOptions) !Self {
        return Self{
            .socket = opts.socket,
            .owner = opts.owner,
            .other = opts.other,
            .is_client = opts.is_client,
            .readable = opts.readable,
            .writable = opts.writable,
            .write_buf = try RingBuffer.init(
                opts.owner.parent.gpa,
                buf_size,
            ),
            .read_buf = try RingBuffer.init(
                opts.owner.parent.gpa,
                buf_size,
            ),
        };
    }

    pub fn deinit(self: *Self) void {
        os.closeSocket(self.socket);
        self.write_buf.deinit(self.owner.parent.gpa);
        self.read_buf.deinit(self.owner.parent.gpa);
    }
};

const TunnelSession = struct {
    const Self = @This();

    parent: *Context,
    client: Connection = undefined,
    remote: Connection = undefined,
    client_buf: RingBuffer = undefined,
    remote_buf: RingBuffer = undefined,
    recv_compl: IO.Completion = undefined,
    send_compl: IO.Completion = undefined,

    const InitOptions = struct {
        parent: *Context,
        client_buf: RingBuffer,
        remote_buf: RingBuffer,
    };

    const ShutdownMode = enum {
        read_only,
        write_only,
        read_write,
    };

    pub fn init(opts: InitOptions) !Self {
        return Self{
            .parent = opts.parent,
            .client_buf = opts.client_buf,
            .remote_buf = opts.remote_buf,
        };
    }

    pub fn start(self: *Self) void {
        //if (!self.client_buf.isEmpty())
        if (self.remote.write_buf.len() > 0)
            self.sendTo(&self.remote);

        //if (!self.client_buf.isFull())
        if (self.client.read_buf.len() == 0)
            self.recvFrom(&self.client);

        //if (!self.remote_buf.isFull())
        if (self.remote.read_buf.len() == 0)
            self.recvFrom(&self.remote);
    }

    pub fn sendTo(
        self: *Self,
        conn: *Connection,
    ) void {
        assert(!conn.write_buf.isFull());
        if (!conn.writable) return;

        if (conn.write_buf.isEmpty())
            conn.write_buf.writeSlice(
                &conn.buffer,
            ) catch |err| {
                log.err("{s}", .{@errorName(err)});
                return;
            };

        conn.sending = true;
        self.parent.io.send(
            *Context,
            self.parent,
            onSendTo,
            &self.send_compl,
            conn.socket,
            conn.write_buf.sliceLast(
                conn.write_buf.len(),
            ).first,
        );
    }

    pub fn onSendTo(
        ctx: *Context,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void {
        _ = completion;
        const ses = &ctx.tunnel;

        var conn = if (ses.client.sending) blk: {
            break :blk &ses.client;
        } else blk: {
            break :blk &ses.remote;
        };

        conn.sending = false;

        var len = result catch |err| switch (err) {
            error.BrokenPipe => {
                ses.stop(conn.other, .read_only);
                return;
            },
            else => {
                log.err("{s}", .{@errorName(err)});
                return;
            },
        };

        const need_read = conn.write_buf.isFull();
        for (0..len) |_| _ = conn.write_buf.read().?;

        if (!conn.write_buf.isEmpty())
            ses.sendTo(conn);

        if (need_read) ses.recvFrom(conn.other);
    }

    pub fn recvFrom(
        self: *Self,
        conn: *Connection,
    ) void {
        assert(!conn.read_buf.isFull());

        if (!conn.readable) return;

        log.info("tunnel recv from", .{});
        conn.recving = true;
        self.parent.io.recv(
            *Context,
            self.parent,
            onRecvFrom,
            &self.recv_compl,
            conn.socket,
            &conn.buffer,
        );
    }

    pub fn onRecvFrom(
        ctx: *Context,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void {
        _ = completion;
        const ses = &ctx.tunnel;

        var conn = if (ses.client.recving) blk: {
            log.info("tunnel recv from client", .{});
            break :blk &ses.client;
        } else blk: {
            log.info("tunnel recv from remote", .{});
            break :blk &ses.remote;
        };

        conn.recving = false;

        var len = result catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        };

        if (len == 0) conn.readable = false;

        const buf = conn.buffer[0..len];
        if (len != 0)
            conn.read_buf.writeSlice(buf) catch |err| {
                log.err("{s}", .{@errorName(err)});
                return;
            };

        var need_write = conn.read_buf.isEmpty();
        for (0..len) |_| _ = conn.read_buf.read().?;

        if (need_write) {
            if (len == 0) {
                ses.stop(conn.other, .write_only);
            } else {
                ses.sendTo(conn.other);
            }
        }

        if (!conn.read_buf.isFull())
            ses.recvFrom(conn);
    }

    pub fn stop(
        self: *Self,
        conn: *Connection,
        mode: ShutdownMode,
    ) void {
        _ = self;
        //defer conn.deinit();
        switch (mode) {
            .read_only => {
                if (!conn.readable)
                    return;
                conn.readable = false;
            },
            .write_only => {
                if (!conn.writable)
                    return;
                conn.writable = false;
            },
            .read_write => {
                if (!conn.readable and
                    !conn.writable)
                    return;
                conn.readable = false;
                conn.writable = false;
            },
        }
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.remote.deinit();
        self.client_buf.deinit(self.parent.gpa);
        self.remote_buf.deinit(self.parent.gpa);
    }
};

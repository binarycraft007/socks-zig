const std = @import("std");
const os = std.os;
const log = std.log;
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const IO = @import("io").IO;
const Server = @import("Server.zig");
const Socks5 = @import("Socks5.zig");

const Client = @This();

pub const ConnState = enum {
    busy, // Busy; waiting for incoming data or for a write to complete.
    done, // Done; read incoming data or write finished.
    stop, // Stopped.
    dead,
};

pub const ConnType = enum {
    client,
    upstream,
};

// Session states.
pub const SessState = enum {
    handshake, // Wait for client handshake.
    handshake_auth, // Wait for client authentication data.
    req_start, // Start waiting for request data.
    req_parse, // Wait for request data.
    req_connect_start, // Wait for upstream hostname DNS lookup to complete.
    req_connect, // Wait for io.connect() to complete.
    proxy_start, // Connected. Start piping data.
    proxy, // Connected. Pipe data back and forth.
    kill, // Tear down session.
    almost_dead_0, // Waiting for finalizers to complete.
    almost_dead_1, // Waiting for finalizers to complete.
    almost_dead_2, // Waiting for finalizers to complete.
    almost_dead_3, // Waiting for finalizers to complete.
    almost_dead_4, // Waiting for finalizers to complete.
    dead, // Dead. Safe to free now.
};

const ConnError = IO.RecvError || IO.SendError;

pub const Connection = struct {
    conn_err: IO.ConnectError!void,
    rdstate: ConnState,
    wrstate: ConnState,
    idle_timeout: u32,
    client: *Client, // Backlink to owning client context.
    result: ConnError!usize,
    handle: os.socket_t,
    address: net.Address,
    buffer: [1 << 14]u8,
    send_compl: IO.Completion,
    recv_compl: IO.Completion,
    close_compl: IO.Completion,
    conn_compl: IO.Completion,
};

state: SessState,
server: *Server, // Backlink to owning server context.
parser: Socks5, // The SOCKS protocol parser.
incoming: *Connection, // Connection with the SOCKS client.
outgoing: *Connection, // Connection with upstream.

pub fn init(server: *Server) !Client {
    var timeout = server.config.idle_timeout;
    var client = Client{
        .state = .handshake,
        .server = server,
        .parser = Socks5.init(),
        .incoming = &Connection{
            .conn_err = undefined,
            .rdstate = .stop,
            .wrstate = .stop,
            .result = 0,
            .client = undefined,
            .buffer = undefined,
            .address = undefined,
            .send_compl = undefined,
            .recv_compl = undefined,
            .close_compl = undefined,
            .conn_compl = undefined,
            .handle = server.client_handle,
            .idle_timeout = timeout,
        },
        .outgoing = &Connection{
            .conn_err = undefined,
            .rdstate = .stop,
            .wrstate = .stop,
            .result = 0,
            .client = undefined,
            .buffer = undefined,
            .address = undefined,
            .send_compl = undefined,
            .recv_compl = undefined,
            .close_compl = undefined,
            .conn_compl = undefined,
            .handle = try server.io.open_socket(
                os.AF.INET,
                os.SOCK.STREAM,
                os.IPPROTO.TCP,
            ),
            .idle_timeout = timeout,
        },
    };

    client.incoming.client = &client;
    client.outgoing.client = &client;

    return client;
}

pub fn deinit(self: *Client) void {
    self.incoming.handle = IO.INVALID_SOCKET;
    self.outgoing.handle = IO.INVALID_SOCKET;
}

pub fn finish(self: *Client) void {
    log.info("start read incoming", .{});
    self.connRecv(self.incoming);
}

fn connRecv(
    self: *Client,
    conn: *Connection,
) void {
    conn.rdstate = .busy;
    self.server.io.recv(
        *Connection,
        conn,
        connRecvDone,
        &conn.recv_compl,
        conn.handle,
        &conn.buffer,
    );
}

fn connRecvDone(
    conn: *Connection,
    completion: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    _ = completion;
    conn.rdstate = .done;
    conn.result = result;
    conn.client.doNext();
}

fn doNext(self: *Client) void {
    self.state = switch (self.state) {
        .handshake => blk: {
            log.info("doHandshake", .{});
            break :blk self.doHandshake();
        },
        .handshake_auth => blk: {
            log.info("doHandshakeAuth", .{});
            break :blk self.doHandshakeAuth();
        },
        .req_start => blk: {
            log.info("doReqStart", .{});
            break :blk self.doReqStart();
        },
        .req_parse => blk: {
            log.info("doReqParse", .{});
            break :blk self.doReqParse();
        },
        .req_connect_start => blk: {
            log.info("doReqConnectStart", .{});
            break :blk self.doReqConnectStart();
        },
        .req_connect => blk: {
            break :blk self.doReqConnect();
        },
        .proxy_start => blk: {
            break :blk self.doProxyStart();
        },
        .proxy => blk: {
            break :blk self.doProxy();
        },
        .kill => blk: {
            log.warn("killing session", .{});
            break :blk self.doKill();
        },
        .almost_dead_0 => blk: {
            // TODO
            break :blk self.state;
        },
        .almost_dead_1 => blk: {
            // TODO
            break :blk self.state;
        },
        .almost_dead_2 => blk: {
            // TODO
            break :blk self.state;
        },
        .almost_dead_3 => blk: {
            // TODO
            break :blk self.state;
        },
        .almost_dead_4 => blk: {
            // TODO
            break :blk self.state;
        },
        .dead => blk: {
            // TODO
            break :blk self.state;
        },
    };

    if (self.state == .dead) {
        self.deinit();
    }
}

fn doHandshake(self: *Client) SessState {
    var len = self.incoming.result catch |err| {
        log.err("{s}", .{@errorName(err)});
        return self.doKill();
    };

    self.incoming.rdstate = .stop;

    var data = self.incoming.buffer[0..len];
    self.parser.parse(data) catch |err| switch (err) {
        error.NeedMoreData => {
            self.connRecv(self.incoming);
            return .handshake;
        },
        error.SelectAuthMethod => {
            if (self.parser.methods.none) {
                self.parser.state = .req_version;
                self.connSend(
                    self.incoming,
                    &[_]u8{ 0x05, 0x00 },
                );
                return .req_start;
            }
        },
        else => {
            log.err("{s}", .{@errorName(err)});
        },
    };
    self.connSend(self.incoming, &[_]u8{ 0x05, 0xFF });
    return .kill;
}

fn doHandshakeAuth(self: *Client) SessState {
    return self.doKill();
}

fn doReqStart(self: *Client) SessState {
    _ = self.incoming.result catch |err| {
        log.err("{s}", .{@errorName(err)});
        return self.doKill();
    };

    assert(self.incoming.rdstate == .stop);
    assert(self.incoming.wrstate == .done);
    self.incoming.wrstate = .stop;

    self.connRecv(self.incoming);
    return .req_parse;
}

fn doReqParse(self: *Client) SessState {
    assert(self.incoming.rdstate == .done);
    assert(self.incoming.wrstate == .stop);
    assert(self.outgoing.rdstate == .stop);
    assert(self.outgoing.wrstate == .stop);
    self.incoming.rdstate = .stop;

    var len = self.incoming.result catch |err| {
        log.err("{s}", .{@errorName(err)});
        return self.doKill();
    };

    var data = self.incoming.buffer[0..len];
    self.parser.parse(data) catch |err| switch (err) {
        error.NeedMoreData => {
            self.connRecv(self.incoming);
            return .req_parse;
        },
        error.ExecuteCommand => {
            switch (self.parser.command) {
                .tcp_connect => {
                    log.info("got tcp connect", .{});
                },
                .tcp_bind => {
                    log.warn("tcp_bind", .{});
                    return self.doKill();
                },
                .udp_assoc => {
                    log.warn("tcp_assoc", .{});
                    return self.doKill();
                },
            }
        },
        else => {
            log.err("{s}", .{@errorName(err)});
            return self.doKill();
        },
    };

    switch (self.parser.addr_type) {
        .host => {
            self.doGetAddrList();
            return .req_connect_start;
        },
        .ipv4 => {
            self.outgoing.address = net.Address.parseIp(
                self.parser.daddr[0..self.parser.addr_len],
                self.parser.dport,
            ) catch |err| {
                log.err("{s}", .{@errorName(err)});
                return self.doKill();
            };
        },
        .ipv6 => {
            self.outgoing.address = net.Address.parseIp(
                self.parser.daddr[0..self.parser.addr_len],
                self.parser.dport,
            ) catch |err| {
                log.err("{s}", .{@errorName(err)});
                return self.doKill();
            };
        },
    }
    return self.doReqConnectStart();
}

fn doReqConnectStart(self: *Client) SessState {
    log.info("{}", .{self.outgoing.address});
    assert(self.incoming.rdstate == .stop);
    assert(self.incoming.wrstate == .stop);
    assert(self.outgoing.rdstate == .stop);
    assert(self.outgoing.wrstate == .stop);

    self.connConnect(self.outgoing);
    return .req_connect;
}

fn doReqConnect(self: *Client) SessState {
    self.outgoing.conn_err catch |err| {
        log.err("{s}", .{@errorName(err)});
        self.connSend(
            self.incoming,
            &[_]u8{ 5, 5, 0, 1, 0, 0, 0, 0, 0, 0 },
        );
        return .kill;
    };
    assert(self.incoming.rdstate == .stop);
    assert(self.incoming.wrstate == .stop);
    assert(self.outgoing.rdstate == .stop);
    assert(self.outgoing.wrstate == .stop);

    var address = self.outgoing.address;
    if (address.any.family == os.AF.INET) {
        var buf: [10]u8 = undefined;
        var addr = mem.asBytes(&address.in.sa.addr);
        var port = @bitCast([2]u8, address.in.sa.port);
        buf[0] = 5; // socks version 5
        buf[1] = 0; // success
        buf[2] = 0; // reserved
        buf[3] = 1; // ipv4 addr type

        inline for (buf[4..8], 0..) |*elem, i|
            elem.* = addr[i];
        buf[8] = port[0]; // port lower byte
        buf[9] = port[1]; // port higher byte

        self.connSend(self.incoming, &buf);
        return .proxy_start;
    } else if (address.any.family == os.AF.INET6) {
        var buf: [22]u8 = undefined;
        var addr = mem.asBytes(&address.in6.sa.addr);
        var port = @bitCast([2]u8, address.in6.sa.port);
        buf[0] = 5; // socks version 5
        buf[1] = 0; // success
        buf[2] = 0; // reserved
        buf[3] = 4; // ipv6 addr type

        inline for (buf[4..20], 0..) |*elem, i|
            elem.* = addr[i];
        buf[20] = port[0]; // port lower byte
        buf[21] = port[1]; // port higher byte

        self.connSend(self.incoming, &buf);
        return .proxy_start;
    }
    unreachable;
}

fn doProxyStart(self: *Client) SessState {
    _ = self.incoming.result catch |err| {
        log.err("{s}", .{@errorName(err)});
        return self.doKill();
    };

    assert(self.incoming.rdstate == .stop);
    assert(self.incoming.wrstate == .done);
    assert(self.outgoing.rdstate == .stop);
    assert(self.outgoing.wrstate == .stop);
    self.incoming.wrstate = .stop;

    self.connRecv(self.incoming);
    self.connRecv(self.outgoing);
    return .proxy;
}

fn doProxy(self: *Client) SessState {
    self.connCycle(self.incoming, self.outgoing) catch
        return self.doKill();

    self.connCycle(self.outgoing, self.incoming) catch
        return self.doKill();

    return .proxy;
}

fn connCycle(self: *Client, a: *Connection, b: *Connection) !void {
    var alen = try a.result;
    var blen = try b.result;

    if (blen == 0 and alen == 0) return error.EndOfStream;

    if (a.wrstate == .done) a.wrstate = .stop;

    if (a.wrstate == .stop) {
        if (b.rdstate == .stop) {
            self.connRecv(b);
        } else if (b.rdstate == .done) {
            self.connSend(a, b.buffer[0..blen]);
            b.rdstate = .stop;
        }
    }
}

fn doGetAddrList(self: *Client) void {
    const func = struct {
        fn func(
            client: *Client,
            callback: *const fn (
                client: *Client,
                result: anyerror!*net.AddressList,
            ) void,
        ) void {
            var len = client.parser.addr_len;
            return callback(
                client,
                net.getAddressList(
                    client.server.allocator,
                    client.parser.daddr[0..len],
                    client.parser.dport,
                ),
            );
        }
    }.func;

    self.server.thread_pool.spawn(
        func,
        .{ self, getAddrListDone },
    ) catch |err| {
        getAddrListDone(self, err);
    };
}

fn getAddrListDone(
    self: *Client,
    result: anyerror!*net.AddressList,
) void {
    var list = result catch |err| {
        log.err("{s}", .{@errorName(err)});
        self.state = .kill;
        self.doNext();
        return;
    };
    defer list.deinit();

    for (list.addrs) |addr| {
        var saddr = self.server.address;
        if (addr.any.family == saddr.any.family) {
            self.outgoing.address = addr;
            self.state = .req_connect_start;
            self.doNext();
            return;
        }
    }

    log.err("UnknownHostName", .{});
    self.state = .kill;
    self.doNext();
}

fn connConnect(
    self: *Client,
    conn: *Connection,
) void {
    self.server.io.connect(
        *Connection,
        conn,
        connConnectDone,
        &conn.conn_compl,
        conn.handle,
        conn.address,
    );
}

fn connConnectDone(
    conn: *Connection,
    completion: *IO.Completion,
    result: IO.ConnectError!void,
) void {
    _ = completion;
    conn.conn_err = result;
    conn.client.doNext();
}

fn connSend(
    self: *Client,
    conn: *Connection,
    bytes: []const u8,
) void {
    conn.wrstate = .busy;
    self.server.io.send(
        *Connection,
        conn,
        connSendDone,
        &conn.send_compl,
        conn.handle,
        bytes,
    );
}

fn connSendDone(
    conn: *Connection,
    completion: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = completion;
    conn.wrstate = .done;
    conn.result = result;
    conn.client.doNext();
}

fn doKill(self: *Client) SessState {
    if (self.state == .almost_dead_0)
        return self.state;

    if (self.incoming.handle != IO.INVALID_SOCKET)
        self.connClose(self.incoming);

    if (self.outgoing.handle != IO.INVALID_SOCKET)
        self.connClose(self.outgoing);

    return .almost_dead_1;
}

fn connClose(
    self: *Client,
    conn: *Connection,
) void {
    conn.rdstate = .dead;
    conn.wrstate = .dead;

    self.server.io.close(
        *Connection,
        conn,
        connCloseDone,
        &conn.close_compl,
        conn.handle,
    );
}

fn connCloseDone(
    self: *Connection,
    completion: *IO.Completion,
    result: IO.CloseError!void,
) void {
    _ = completion;
    result catch unreachable;
    self.client.doNext();
}

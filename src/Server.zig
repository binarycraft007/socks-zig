const std = @import("std");
const os = std.os;
const log = std.log;
const mem = std.mem;
const net = std.net;
const IO = @import("io").IO;
const Socks5 = @import("Socks5.zig");
const Client = @import("Client.zig");
const ThreadPool = std.Thread.Pool;
const MemoryPool = std.heap.MemoryPool;

pub const Config = struct {
    bind_host: []const u8,
    bind_port: u16,
    idle_timeout: u32,
};

const Server = @This();

const ClientPool = MemoryPool(Client);
const CompletionPool = MemoryPool(IO.Completion);
const ConnectionPool = MemoryPool(Client.Connection);

io: IO,
config: Config,
address: net.Address,
tcp_handle: os.socket_t,
compl_pool: CompletionPool,
conn_pool: ConnectionPool,
allocator: mem.Allocator,
thread_pool: ThreadPool,
client_handle: os.socket_t,
remote_handle: os.socket_t,
client_pool: ClientPool,

pub fn init(gpa: mem.Allocator, io: IO, cfg: Config) Server {
    return .{
        .io = io,
        .config = cfg,
        .address = undefined,
        .allocator = gpa,
        .tcp_handle = undefined,
        .thread_pool = undefined,
        .client_handle = undefined,
        .remote_handle = undefined,
        .conn_pool = ConnectionPool.init(gpa),
        .compl_pool = CompletionPool.init(gpa),
        .client_pool = ClientPool.init(gpa),
    };
}

pub fn deinit(self: *Server) void {
    self.config = undefined;
    os.closeSocket(self.tcp_handle);
}

pub fn run(self: *Server) !void {
    try self.thread_pool.init(.{ .allocator = self.allocator });

    self.tcp_handle = try self.io.open_socket(
        os.AF.INET,
        os.SOCK.STREAM,
        os.IPPROTO.TCP,
    );

    try os.setsockopt(
        self.tcp_handle,
        os.SOL.SOCKET,
        os.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    self.address = try net.Address.parseIp(
        self.config.bind_host,
        self.config.bind_port,
    );

    try os.bind(
        self.tcp_handle,
        &self.address.any,
        self.address.getOsSockLen(),
    );
    try os.listen(self.tcp_handle, 1);

    self.acceptConnection();
    while (true) {
        const timeout_ns = 1 * 60 * std.time.ns_per_s;
        try self.io.run_for_ns(@intCast(u63, timeout_ns));
    }
}

pub fn acceptConnection(self: *Server) void {
    self.io.accept(
        *Server,
        self,
        onAcceptConnection,
        self.compl_pool.create() catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        },
        self.tcp_handle,
    );
}

fn onAcceptConnection(
    self: *Server,
    completion: *IO.Completion,
    result: IO.AcceptError!os.socket_t,
) void {
    defer self.compl_pool.destroy(completion);
    self.acceptConnection();

    var client_handle = result catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };

    var client = self.client_pool.create() catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };

    var timeout = self.config.idle_timeout;
    client.* = Client{
        .state = .handshake,
        .server = self,
        .parser = Socks5.init(),
        .incoming = self.conn_pool.create() catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        },
        .outgoing = self.conn_pool.create() catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        },
        .active_conns = 2,
    };

    client.incoming.rdstate = .stop;
    client.incoming.wrstate = .stop;
    client.incoming.result = 0;
    client.incoming.handle = client_handle;
    client.incoming.idle_timeout = timeout;
    client.incoming.client = client;

    client.outgoing.rdstate = .stop;
    client.outgoing.wrstate = .stop;
    client.outgoing.result = 0;
    client.outgoing.handle = self.io.open_socket(
        os.AF.INET,
        os.SOCK.STREAM,
        os.IPPROTO.TCP,
    ) catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };
    client.outgoing.idle_timeout = timeout;
    client.outgoing.client = client;

    client.finish();
}

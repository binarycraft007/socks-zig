const std = @import("std");
const os = std.os;
const log = std.log;
const mem = std.mem;
const net = std.net;
const IO = @import("io").IO;
const Client = @import("Client.zig");
const ThreadPool = @import("ThreadPool.zig");
const MemoryPool = std.heap.MemoryPool;

pub const Config = struct {
    bind_host: []const u8,
    bind_port: u16,
    idle_timeout: u32,
};

const Server = @This();

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

pub fn init(gpa: mem.Allocator, io: IO, cfg: Config) Server {
    return Server{
        .io = io,
        .address = undefined,
        .allocator = gpa,
        .tcp_handle = undefined,
        .thread_pool = undefined,
        .client_handle = undefined,
        .remote_handle = undefined,
        .conn_pool = ConnectionPool.init(gpa),
        .compl_pool = CompletionPool.init(gpa),
        .config = cfg,
    };
}

pub fn deinit(self: *Server) void {
    self.config = undefined;
    os.closeSocket(self.tcp_handle);
}

pub fn run(self: *Server) !void {
    try self.thread_pool.init(self.allocator);

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
    var tick: usize = 0xdeadbeef;
    while (true) : (tick +%= 1) {
        if (tick % 61 == 0) {
            const timeout_ns = tick % (10 * std.time.ns_per_ms);
            try self.io.run_for_ns(@intCast(u63, timeout_ns));
        } else {
            try self.io.tick();
        }
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
    self.compl_pool.destroy(completion);

    self.client_handle = result catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };

    var client = Client.init(self) catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };
    client.finish();
    self.acceptConnection();
}

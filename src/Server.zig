const std = @import("std");
const os = std.os;
const log = std.log;
const mem = std.mem;
const net = std.net;
const IO = @import("io").IO;
const Client = @import("Client.zig");
const ThreadPool = @import("ThreadPool.zig");

pub const Config = struct {
    bind_host: []const u8,
    bind_port: u16,
    idle_timeout: u32,
};

const Server = @This();

io: IO,
config: Config,
address: net.Address,
tcp_handle: os.socket_t,
accp_compl: IO.Completion,
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
        .accp_compl = undefined,
        .client_handle = undefined,
        .remote_handle = undefined,
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
        &self.accp_compl,
        self.tcp_handle,
    );
}

fn onAcceptConnection(
    self: *Server,
    completion: *IO.Completion,
    result: IO.AcceptError!os.socket_t,
) void {
    _ = completion;
    self.acceptConnection();

    self.client_handle = result catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };

    var client = Client.init(self) catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };
    client.finish();
}

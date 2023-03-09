const std = @import("std");
const fmt = std.fmt;
const log = std.log;
const Socks5 = @This();

pub const State = enum {
    version,
    nmethods,
    methods,
    auth_pw_version,
    auth_pw_userlen,
    auth_pw_username,
    auth_pw_passlen,
    auth_pw_password,
    req_version,
    req_command,
    req_reserved,
    req_atyp,
    req_atyp_host,
    req_daddr,
    req_dport0,
    req_dport1,
    dead,
};

pub const Error = error{
    BadProtocolVersion,
    BadProtocolCommand,
    BadAddressType,
    SelectAuthMethod,
    VerifyAuthentication,
    ExecuteCommand,
    NeedMoreData,
} || fmt.BufPrintError;

pub const AuthMethod = enum(u8) {
    none = 0x00,
    gssapi = 0x01,
    passwd = 0x02,
};

pub const MethodFlag = packed struct {
    none: bool = false,
    gssapi: bool = false,
    passwd: bool = false,
};

pub const AuthResult = enum {
    allow,
    deny,
};

pub const AddrType = enum(u8) {
    ipv4 = 0x01,
    host = 0x03,
    ipv6 = 0x4,
};

pub const Command = enum(u8) {
    tcp_connect = 0x01,
    tcp_bind = 0x02,
    udp_assoc = 0x03,
};

arg0: u32, // Scratch space for the state machine
arg1: u32, // Scratch space for the state machine
state: State,
methods: MethodFlag,
command: Command,
addr_type: AddrType,
addr_len: usize,
user_len: u8,
pass_len: u8,
dport: u16,
username: [257]u8,
password: [257]u8,
daddr: [257]u8, // TODO Merge with username/password.

pub fn init() Socks5 {
    return Socks5{
        .arg0 = 0,
        .arg1 = 0,
        .state = .version,
        .methods = MethodFlag{
            .none = false,
            .passwd = false,
            .gssapi = false,
        },
        .command = .tcp_connect,
        .addr_type = .ipv4,
        .addr_len = 0,
        .dport = 0,
        .user_len = 0,
        .pass_len = 0,
        .username = [_]u8{0} ** 257,
        .password = [_]u8{0} ** 257,
        .daddr = [_]u8{0} ** 257,
    };
}

pub fn deinit(self: *Socks5) void {
    self.arg0 = undefined;
    self.arg1 = undefined;
    self.state = undefined;
    self.methods = undefined;
    self.command = undefined;
    self.addr_type = undefined;
    self.addr_len = undefined;
    self.user_len = undefined;
    self.pass_len = undefined;
    self.username = undefined;
    self.password = undefined;
    self.daddr = undefined;
}

pub fn parse(self: *Socks5, data: []u8) Error!void {
    for (data) |c| {
        switch (self.state) {
            .version => {
                if (c != 5)
                    return error.BadProtocolVersion;
                self.state = .nmethods;
            },
            .nmethods => {
                self.arg0 = 0;
                self.arg1 = c;
                self.state = .methods;
            },
            .methods => {
                if (self.arg0 < self.arg1) {
                    switch (@intToEnum(AuthMethod, c)) {
                        .none => self.methods.none = true,
                        .passwd => self.methods.passwd = true,
                        .gssapi => self.methods.gssapi = true,
                    }
                }
                self.arg0 += 1;
                if (self.arg0 == self.arg1)
                    return error.SelectAuthMethod;
            },
            .auth_pw_version => {
                if (c != 1)
                    return error.BadProtocolVersion;
                self.state = .auth_pw_userlen;
            },
            .auth_pw_userlen => {
                self.arg0 = 0;
                self.user_len = c;
                self.state = .auth_pw_username;
            },
            .auth_pw_username => {
                if (self.arg0 < self.user_len) {
                    self.username[self.arg0] = c;
                    self.arg0 += 1;
                }
                if (self.arg0 == self.user_len) {
                    self.state = .auth_pw_passlen;
                }
            },
            .auth_pw_passlen => {
                self.arg0 = 0;
                self.pass_len = c;
                self.state = .auth_pw_password;
            },
            .auth_pw_password => {
                if (self.arg0 < self.pass_len) {
                    self.password[self.arg0] = c;
                    self.arg0 += 1;
                }
                if (self.arg0 == self.pass_len) {
                    self.state = .req_version;
                    return error.VerifyAuthentication;
                }
            },
            .req_version => {
                if (c != 5)
                    return error.BadProtocolVersion;
                self.state = .req_command;
            },
            .req_command => {
                self.command = @intToEnum(Command, c);
                self.state = .req_reserved;
            },
            .req_reserved => {
                self.state = .req_atyp;
            },
            .req_atyp => {
                self.arg0 = 0;
                self.addr_len = 0;
                self.addr_type = @intToEnum(AddrType, c);
                switch (self.addr_type) {
                    .ipv4 => {
                        self.state = .req_daddr;
                        self.arg1 = 4;
                    },
                    .host => {
                        self.state = .req_atyp_host;
                        self.arg1 = 0;
                    },
                    .ipv6 => {
                        self.state = .req_daddr;
                        self.arg1 = 16;
                    },
                }
            },
            .req_atyp_host => {
                self.arg1 = c;
                self.addr_len = c;
                self.state = .req_daddr;
            },
            .req_daddr => {
                if (self.arg0 < self.arg1) {
                    self.daddr[self.arg0] = c;
                    self.arg0 += 1;
                }
                if (self.arg0 == self.arg1) {
                    var buf: [257]u8 = undefined;
                    if (self.arg1 == 4) {
                        var addr = try fmt.bufPrint(
                            &buf,
                            "{}.{}.{}.{}",
                            .{
                                self.daddr[0],
                                self.daddr[1],
                                self.daddr[2],
                                self.daddr[3],
                            },
                        );
                        self.addr_len = addr.len;
                        for (addr, 0..) |elem, i|
                            self.daddr[i] = elem;
                    } else if (self.arg1 == 16) {
                        var addr = try fmt.bufPrint(
                            &buf,
                            "{x:0>2}{x:0>2}:" ++
                                "{x:0>2}{x:0>2}:" ++
                                "{x:0>2}{x:0>2}:" ++
                                "{x:0>2}{x:0>2}:" ++
                                "{x:0>2}{x:0>2}:" ++
                                "{x:0>2}{x:0>2}:" ++
                                "{x:0>2}{x:0>2}:" ++
                                "{x:0>2}{x:0>2}",
                            .{
                                self.daddr[0],
                                self.daddr[1],
                                self.daddr[2],
                                self.daddr[3],
                                self.daddr[4],
                                self.daddr[5],
                                self.daddr[6],
                                self.daddr[7],
                                self.daddr[8],
                                self.daddr[9],
                                self.daddr[10],
                                self.daddr[11],
                                self.daddr[12],
                                self.daddr[13],
                                self.daddr[14],
                                self.daddr[15],
                            },
                        );
                        self.addr_len = addr.len;
                        for (addr, 0..) |elem, i|
                            self.daddr[i] = elem;
                    }
                    self.state = .req_dport0;
                }
            },
            .req_dport0 => {
                self.dport = @as(u16, c) << 8;
                self.state = .req_dport1;
            },
            .req_dport1 => {
                self.dport |= c;
                self.state = .dead;
                return error.ExecuteCommand;
            },
            .dead => {},
        }
    }
    return error.NeedMoreData;
}

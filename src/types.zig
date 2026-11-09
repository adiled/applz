//! The run spec: what `applz run` needs beyond the image, as JSON. Given as a
//! file (`--spec <path>`) or inline (`--spec-base64 <data>`) so callers that
//! put the command in a shell line never have to quote it.
//!
//!   {
//!     "entrypoint": "/docker-entrypoint.sh",   replaces the image's ENTRYPOINT
//!     "cmd": "postgres -c fsync=off",           replaces the image's CMD
//!     "workdir": "/app",
//!     "user": "999:999",
//!     "env": ["POSTGRES_PASSWORD=secret"],      appended to the image's env
//!     "mounts": [{"source": "/Users/me/pg", "destination": "/var/lib/postgresql/data"}],
//!     "ports": [{"host": 5432, "container": 5432, "address": "127.0.0.1"}],
//!     "memory": "1G",                           VM RAM: K, M or G
//!     "cpus": 2,                                vCPUs, rounded up
//!     "limits": {"nofile": 4096, "nproc": 512, "pids": 256, "io_weight": 100, "cpu_quota": "50%"}
//!   }
//!
//! Every field is optional. Mount sources are host paths, used as given.

const std = @import("std");

pub const Port = struct {
    address: ?[]const u8 = null,
    host: u16,
    container: u16,
};

pub const Mount = struct {
    source: []const u8,
    destination: []const u8,
};

pub const Limits = struct {
    nofile: ?u64 = null,
    nproc: ?u64 = null,
    pids: ?u64 = null,
    io_weight: ?u32 = null,
    cpu_quota: ?[]const u8 = null,
};

pub const RunSpec = struct {
    entrypoint: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    user: ?[]const u8 = null,
    env: []const []const u8 = &.{},
    mounts: []const Mount = &.{},
    ports: []const Port = &.{},
    memory: ?[]const u8 = null,
    cpus: ?f64 = null,
    limits: Limits = .{},
};

pub fn parseRunSpec(arena: std.mem.Allocator, json: []const u8) !RunSpec {
    return std.json.parseFromSliceLeaky(RunSpec, arena, json, .{ .allocate = .alloc_always });
}

test "a run spec takes every field, and none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try parseRunSpec(a,
        \\{"entrypoint":"/e.sh","cmd":"serve","workdir":"/app","user":"999",
        \\ "env":["A=1"],"mounts":[{"source":"/h","destination":"/g"}],
        \\ "ports":[{"host":8080,"container":80}],"memory":"1G","cpus":1.5,
        \\ "limits":{"nofile":4096,"pids":64,"cpu_quota":"50%"}}
    );
    try std.testing.expectEqualStrings("/e.sh", full.entrypoint.?);
    try std.testing.expectEqualStrings("A=1", full.env[0]);
    try std.testing.expectEqualStrings("/g", full.mounts[0].destination);
    try std.testing.expectEqual(8080, full.ports[0].host);
    try std.testing.expectEqual(64, full.limits.pids.?);
    const empty = try parseRunSpec(a, "{}");
    try std.testing.expectEqual(0, empty.env.len);
    try std.testing.expectEqual(null, empty.memory);
}

test "a run spec refuses fields it does not know, so typos are loud" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownField, parseRunSpec(arena.allocator(), "{\"volumes\":[]}"));
}

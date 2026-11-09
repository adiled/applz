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

/// Split `entrypoint` / `cmd` into argv the way a POSIX shell splits words:
/// whitespace separates, '...' is literal, "..." keeps \" \\ \$ \` escapes, and a
/// backslash outside quotes takes the next character as-is.
pub fn words(arena: std.mem.Allocator, s: []const u8) error{ UnterminatedQuote, OutOfMemory }![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            ' ', '\t', '\n' => if (in_word) {
                try out.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            },
            '\'' => {
                in_word = true;
                const end = std.mem.indexOfScalarPos(u8, s, i + 1, '\'') orelse return error.UnterminatedQuote;
                try word.appendSlice(arena, s[i + 1 .. end]);
                i = end;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (true) : (i += 1) {
                    if (i >= s.len) return error.UnterminatedQuote;
                    if (s[i] == '"') break;
                    if (s[i] == '\\' and i + 1 < s.len and std.mem.indexOfScalar(u8, "\"\\$`", s[i + 1]) != null) i += 1;
                    try word.append(arena, s[i]);
                }
            },
            '\\' => {
                in_word = true;
                if (i + 1 < s.len) {
                    i += 1;
                    try word.append(arena, s[i]);
                }
            },
            else => {
                in_word = true;
                try word.append(arena, c);
            },
        }
    }
    if (in_word) try out.append(arena, try word.toOwnedSlice(arena));
    return out.items;
}

test "cmd splits into words like a shell, quotes and all" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try words(a, "sh -c 'echo hello from $GREETING; cat /data/note'  \"a \\\"b\\\"\" c\\ d e''f");
    try std.testing.expectEqual(6, argv.len);
    try std.testing.expectEqualStrings("sh", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("echo hello from $GREETING; cat /data/note", argv[2]);
    try std.testing.expectEqualStrings("a \"b\"", argv[3]);
    try std.testing.expectEqualStrings("c d", argv[4]);
    try std.testing.expectEqualStrings("ef", argv[5]);
    const empty_quoted = try words(a, "run ''");
    try std.testing.expectEqual(2, empty_quoted.len);
    try std.testing.expectEqualStrings("", empty_quoted[1]);
    try std.testing.expectEqual(0, (try words(a, "   ")).len);
    try std.testing.expectError(error.UnterminatedQuote, words(a, "sh -c 'echo"));
    try std.testing.expectError(error.UnterminatedQuote, words(a, "\"half"));
}

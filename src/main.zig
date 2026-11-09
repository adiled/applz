//! applz — a lean container runtime over Apple Virtualization.
//!
//! Each container is its own small Linux VM: Virtualization.framework boots our
//! pinned kernel with the image's rootfs as an initramfs, our guest init runs
//! the container's process, and stdio and exit status come back over vsock.
//! No daemon: the VM lives as long as `applz run`.
//!
//!   applz check                                  is Virtualization.framework usable here
//!   applz pull <image>                           fetch and cache an image
//!   applz run <name> <image> [--spec <file> | --spec-base64 <data>]
//!                                                boot it and run it in the foreground
//!   applz stop <name>                            stop a running container
//!   applz rm <name>                              remove a container's state
//!   applz selftest                               boot the kernel alone
//!   applz selftest-run                           boot and run the bundled payload
//!
//! The run spec (see types.zig) carries env, mounts, ports, user, workdir,
//! entrypoint, cmd, memory, cpus and limits.
const std = @import("std");

const types = @import("types.zig");
const vz = @import("vz.zig");
const vm = @import("vm.zig");
const kernel = @import("kernel.zig");
const proto = @import("proto.zig");

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    _ = it.skip(); // argv[0]

    const command = it.next() orelse usage();
    const arg = it.next();

    if (std.mem.eql(u8, command, "check")) {
        cmdCheck();
    } else if (std.mem.eql(u8, command, "pull")) {
        cmdPull(allocator, io, arg orelse usage());
    } else if (std.mem.eql(u8, command, "run")) {
        const image = it.next() orelse usage();
        cmdRun(allocator, io, arg orelse usage(), image, &it);
    } else if (std.mem.eql(u8, command, "stop")) {
        cmdStop(allocator, arg orelse usage());
    } else if (std.mem.eql(u8, command, "rm")) {
        cmdRemove(allocator, arg orelse usage());
    } else if (std.mem.eql(u8, command, "selftest")) {
        try cmdSelftest(allocator);
    } else if (std.mem.eql(u8, command, "selftest-run")) {
        try cmdRunTest(allocator, io);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        std.debug.print("applz {s}\n", .{@import("build_options").version});
    } else {
        usage();
    }
}

fn usage() noreturn {
    std.debug.print(
        \\usage: applz check
        \\       applz pull <image>
        \\       applz run <name> <image> [--spec <file> | --spec-base64 <data>]
        \\       applz stop <name>
        \\       applz rm <name>
        \\       applz selftest | selftest-run | version
        \\
    , .{});
    std.process.exit(2);
}

fn cmdCheck() void {
    if (vz.available()) {
        std.debug.print("applz ok: Virtualization.framework backend ready\n", .{});
        return;
    }
    std.debug.print("error: Virtualization.framework backend unavailable on this host\n", .{});
    std.process.exit(1);
}

/// pull: pre-fetch + cache the image so a later run starts fast (pre_start).
fn cmdPull(allocator: std.mem.Allocator, io: std.Io, image: []const u8) void {
    vz.pullImage(allocator, io, image) catch |err| {
        std.debug.print("applz pull {s}: {s}\n", .{ image, @errorName(err) });
        std.process.exit(1);
    };
    std.debug.print("applz pull: {s} cached\n", .{image});
}

/// selftest: boot our pinned kernel with NO rootfs and confirm VZ's start
/// completion fires without error. The kernel will panic ("unable to mount
/// root") inside the guest, but that happens AFTER a successful start, so a
/// clean start proves the entitlement + kernel + our VZ config all work. The
/// serial console is wired to stderr, so guest boot logs print here.
fn cmdSelftest(allocator: std.mem.Allocator) !void {
    const kpath = kernel.kernelPath(allocator) catch |err| {
        std.debug.print("selftest: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(kpath);
    const kpath_z = try allocator.dupeSentinel(u8, kpath, 0);
    defer allocator.free(kpath_z);

    std.debug.print("selftest: booting {s} (no rootfs)\n", .{kpath_z});

    const spec = vm.BootSpec{
        .kernel_path = kpath_z,
        .cmdline = "console=hvc0",
        .rootfs_path = "/nonexistent-rootfs",
        .cpu_count = 1,
        .memory_bytes = 512 * 1024 * 1024,
        .vsock_port = 1024,
    };

    var machine = vm.boot(spec) catch |err| {
        std.debug.print("selftest: BOOT FAILED ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.debug.print("selftest: VZ start SUCCEEDED (entitlement + kernel + config OK)\n", .{});
    _ = csleep(3); // let the kernel print to the console
    machine.shutdown();
    std.debug.print("selftest: shut down. ok.\n", .{});
}

/// selftest-run: the full pipeline against a controlled rootfs (no network).
/// Builds an ext4 with a tiny static payload, boots it, and runs the payload
/// over vsock. Proves ext4 mount + guest init as PID 1 + vsock exec + exit code.
fn cmdRunTest(allocator: std.mem.Allocator, io: std.Io) !void {
    const rootfs = "/tmp/applz-runtest/rootfs";
    std.Io.Dir.cwd().createDirPath(io, rootfs) catch {};

    const payload = readPayload(allocator, io) catch |e| {
        std.debug.print("selftest-run: cannot read payload binary ({s})\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer allocator.free(payload);

    const ppath = rootfs ++ "/payload";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ppath, .data = payload }) catch |e| {
        std.debug.print("selftest-run: cannot write payload ({s})\n", .{@errorName(e)});
        std.process.exit(1);
    };
    _ = chmod(ppath, 0o755);

    const spec = proto.ExecSpec{ .argv = &.{"/payload"}, .env = &.{}, .cwd = "/" };
    std.debug.print("selftest-run: booting container, exec /payload ...\n", .{});

    const code = vz.runRootfs(allocator, io, "runtest", rootfs, spec, .{}) catch |e| {
        std.debug.print("selftest-run: FAILED ({s})\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("selftest-run: container exited with code {d}\n", .{code});
    std.process.exit(@intCast(code));
}

/// Read the test payload binary: $APPLZ_PAYLOAD, else next to this exe.
fn readPayload(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (getenv("APPLZ_PAYLOAD")) |p| {
        return std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(p), allocator, .unlimited);
    }
    const dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/applz-payload", .{dir});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

extern "c" fn sleep(seconds: c_uint) c_uint;
fn csleep(seconds: c_uint) c_uint {
    return sleep(seconds);
}

fn cmdRun(allocator: std.mem.Allocator, io: std.Io, id: []const u8, image: []const u8, it: *std.process.Args.Iterator) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var spec: types.RunSpec = .{};
    while (it.next()) |flag| {
        const value = it.next() orelse usage();
        const json = if (std.mem.eql(u8, flag, "--spec"))
            std.Io.Dir.cwd().readFileAlloc(io, value, arena, .limited(1 << 20)) catch |err| fail("run {s}: cannot read spec {s}: {s}", .{ id, value, @errorName(err) })
        else if (std.mem.eql(u8, flag, "--spec-base64"))
            decodeBase64(arena, value) catch fail("run {s}: --spec-base64 is not base64", .{id})
        else
            usage();
        spec = types.parseRunSpec(arena, json) catch |err| fail("run {s}: bad spec: {s}", .{ id, @errorName(err) });
    }
    for ([_]struct { []const u8, ?[]const u8 }{ .{ "entrypoint", spec.entrypoint }, .{ "cmd", spec.cmd } }) |field| {
        const text = field[1] orelse continue;
        _ = types.words(arena, text) catch fail("run {s}: {s} has an unterminated quote: {s}", .{ id, field[0], text });
    }

    const code = vz.run(allocator, io, id, image, overrides(spec)) catch |err| fail("run {s}: {s}", .{ id, @errorName(err) });
    std.process.exit(@intCast(code));
}

fn decodeBase64(arena: std.mem.Allocator, b64: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const out = try arena.alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(out, b64);
    return out;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("applz " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn overrides(spec: types.RunSpec) vz.Overrides {
    var limits = proto.Limits{};
    if (spec.limits.nofile) |n| limits.nofile = n;
    if (spec.limits.nproc) |n| limits.nproc = n;
    if (spec.limits.pids) |n| limits.pids_max = n;
    if (spec.limits.io_weight) |w| limits.io_weight = w;
    if (spec.limits.cpu_quota) |q| {
        if (parseCpuQuota(q)) |cq| {
            limits.cpu_quota_us = cq.quota_us;
            limits.cpu_period_us = cq.period_us;
        }
    }
    return .{
        .env = spec.env,
        .entrypoint = spec.entrypoint,
        .cmd = spec.cmd,
        .workdir = spec.workdir,
        .memory_mb = if (spec.memory) |m| parseMemoryMb(m) else null,
        .cpus = if (spec.cpus) |c| cpusToCount(c) else null,
        .user = spec.user,
        .limits = limits,
        .mounts = spec.mounts,
        .publish = spec.ports,
    };
}

/// Parse a CPU quota string into a cgroup v2 cpu.max (quota,period) pair in
/// microseconds. Accepts "50%" (systemd style) or a bare number treated as a
/// percentage. period is fixed at 100000us. Returns null if unparseable.
fn parseCpuQuota(s: []const u8) ?struct { quota_us: u64, period_us: u64 } {
    const t = std.mem.trim(u8, s, " \t%");
    const pct = std.fmt.parseInt(u64, t, 10) catch return null;
    if (pct == 0) return null;
    const period: u64 = 100000;
    return .{ .quota_us = pct * period / 100, .period_us = period };
}

/// Parse a memory size string into megabytes for the VM RAM. Accepts k/m/g (and
/// the Ki/Mi/Gi variants) suffixes, case-insensitive; a bare number is bytes.
/// Returns null if unparseable (caller falls back to the default).
fn parseMemoryMb(s: []const u8) ?u64 {
    const t = std.mem.trim(u8, s, " \t");
    var end: usize = 0;
    while (end < t.len and t[end] >= '0' and t[end] <= '9') end += 1;
    if (end == 0) return null;
    const num = std.fmt.parseInt(u64, t[0..end], 10) catch return null;
    const suffix = std.mem.trim(u8, t[end..], " \t");
    var bytes: u64 = num;
    if (suffix.len > 0) {
        bytes = switch (std.ascii.toLower(suffix[0])) {
            'k' => num * 1024,
            'm' => num * 1024 * 1024,
            'g' => num * 1024 * 1024 * 1024,
            else => num,
        };
    }
    const mb = bytes / (1024 * 1024);
    return if (mb == 0) 1 else mb;
}

/// Round a fractional CPU request up to whole vCPUs (min 1).
fn cpusToCount(c: f64) usize {
    if (c <= 1.0) return 1;
    return @intFromFloat(@ceil(c));
}

fn cmdStop(allocator: std.mem.Allocator, id: []const u8) void {
    vz.stop(allocator, id) catch |err| fail("stop {s}: {s}", .{ id, @errorName(err) });
}

fn cmdRemove(allocator: std.mem.Allocator, id: []const u8) void {
    vz.delete(allocator, id) catch |err| fail("rm {s}: {s}", .{ id, @errorName(err) });
}

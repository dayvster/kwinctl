//! The Linux system calls kwinctl needs, with errno handling in one place.
//!
//! These are raw syscalls rather than libc calls, so kwinctl builds as a small static binary
//! with no runtime dependencies. Interrupted calls are retried.
const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    /// The kernel refused the call (missing file, closed socket, no permission, ...).
    SystemCallFailed,
    /// A socket path longer than a Unix socket address can hold.
    TooLarge,
};

/// A point in time on the monotonic clock, for operations that must finish within a limit.
pub const Deadline = struct {
    ns: i128,

    /// The deadline `ms` milliseconds from now.
    pub fn in(ms: u32) Deadline {
        return .{ .ns = monotonicNs() + @as(i128, ms) * std.time.ns_per_ms };
    }

    /// Milliseconds left (rounded up), or null once the deadline has passed.
    pub fn remainingMs(d: Deadline) ?i32 {
        const left = d.ns - monotonicNs();
        if (left <= 0) return null;
        const ms = @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(ms, std.math.maxInt(i32)));
    }
};

fn monotonicNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Turns a syscall's return value into a file descriptor.
fn fdFrom(rc: usize) Error!i32 {
    if (linux.errno(rc) != .SUCCESS) return error.SystemCallFailed;
    return @intCast(rc);
}

/// A signal interrupted the call, or it would block: try again.
fn interrupted(rc: usize) bool {
    return switch (linux.errno(rc)) {
        .INTR, .AGAIN => true,
        else => false,
    };
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}

/// The real user id of this process.
pub fn uid() u32 {
    return linux.getuid();
}

/// The id of this process.
pub fn pid() u32 {
    return @intCast(linux.getpid());
}

/// Writes all of `bytes`, however many write calls that takes.
pub fn writeAll(fd: i32, bytes: []const u8) Error!void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (interrupted(rc)) continue;
        if (linux.errno(rc) != .SUCCESS) return error.SystemCallFailed;
        done += rc;
    }
}

/// Reads what is available, up to buf.len bytes. Returns 0 when the other end has closed.
pub fn read(fd: i32, buf: []u8) Error!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        if (interrupted(rc)) continue;
        if (linux.errno(rc) != .SUCCESS) return error.SystemCallFailed;
        return rc;
    }
}

/// Waits until `fd` has data to read. Returns false if the deadline passes first.
pub fn waitReadable(fd: i32, deadline: Deadline) Error!bool {
    while (true) {
        const ms = deadline.remainingMs() orelse return false;
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&pfd, 1, ms);
        if (interrupted(rc)) continue;
        if (linux.errno(rc) != .SUCCESS) return error.SystemCallFailed;
        if (rc > 0) return true;
    }
}

/// Creates a new file at `path` that only this user can read, containing `data`. Fails if
/// the file already exists, so an existing file is never overwritten or read by mistake.
pub fn createPrivateFile(path: [:0]const u8, data: []const u8) Error!void {
    const fd = try fdFrom(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600));
    defer close(fd);
    try writeAll(fd, data);
}

/// Deletes a file, ignoring errors (for cleanup).
pub fn deleteFile(path: [:0]const u8) void {
    _ = linux.unlink(path);
}

/// Connects a Unix stream socket and returns its file descriptor.
///
/// With `abstract`, `path` is a name in Linux's abstract socket namespace rather than a file.
/// Abstract names are written after a leading nul byte and have no terminating nul;
/// filesystem paths are nul-terminated.
pub fn connectUnix(path: []const u8, abstract: bool) Error!i32 {
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    const start: usize = @intFromBool(abstract);
    if (start + path.len >= addr.path.len) return error.TooLarge;
    @memcpy(addr.path[start..][0..path.len], path);
    const used = start + path.len + @intFromBool(!abstract);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + used);

    const fd = try fdFrom(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    errdefer close(fd);
    while (true) {
        const rc = linux.connect(fd, &addr, len);
        if (interrupted(rc)) continue;
        if (linux.errno(rc) != .SUCCESS) return error.SystemCallFailed;
        return fd;
    }
}

test "a deadline in the future has time left, one in the past has none" {
    try std.testing.expect(Deadline.in(10_000).remainingMs().? > 9_000);
    try std.testing.expect((Deadline{ .ns = monotonicNs() - 1 }).remainingMs() == null);
}

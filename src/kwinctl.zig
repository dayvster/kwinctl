//! kwinctl: list and control KDE Plasma 6 (KWin) windows from Zig, with no dependencies.
//!
//! KWin only shows its windows to its own scripts, so every operation is a small JavaScript
//! program: kwinctl writes it to a private temp file, asks KWin over D-Bus to load and run it,
//! and the script sends its answer back to kwinctl's D-Bus connection.
//!
//!     var client = try kwinctl.Client.init(gpa, .{ .bus_address = bus, .runtime_dir = xdg_runtime });
//!     defer client.deinit();
//!     const list = try client.windows(gpa, .{});
//!     defer list.deinit();
//!     try client.focus(list.value[0].id);
const std = @import("std");
const types = @import("types.zig");
const window_id = @import("window_id.zig");

/// The connection to KWin; start here.
pub const Client = @import("Client.zig");
pub const Window = types.Window;
pub const Screen = types.Screen;
pub const Rect = types.Rect;
/// The D-Bus client kwinctl is built on, for callers that need the bus directly.
pub const dbus = @import("dbus.zig");

/// Checks a window id and returns it as "{lowercase-uuid}" in the buffer, or null if it
/// isn't a UUID.
pub const normalizeId = window_id.normalize;
/// Storage for normalizeId's result.
pub const IdBuffer = window_id.Buffer;

test {
    _ = types;
    _ = window_id;
    _ = dbus;
    _ = @import("sys.zig");
    _ = @import("scripts.zig");
    _ = Client;
}

// Needs a running KWin with at least one window, as tests/run-headless.sh provides (it sets
// KWINCTL_TEST_SOCKET); skipped otherwise. The test allocator fails the test on any leak.
test "every client operation against a live KWin, without leaking" {
    const env = std.testing.environ;
    if (env.getPosix("KWINCTL_TEST_SOCKET") == null) return error.SkipZigTest;
    const a = std.testing.allocator;

    var client = try Client.init(a, .{
        .bus_address = env.getPosix("DBUS_SESSION_BUS_ADDRESS").?,
        .runtime_dir = env.getPosix("XDG_RUNTIME_DIR"),
    });
    defer client.deinit();

    const list = try client.windows(a, .{ .all = true });
    defer list.deinit();
    try std.testing.expect(list.value.len > 0);
    const id = list.value[0].id;

    if (try client.activeWindow(a)) |active| active.deinit();
    const outputs = try client.screens(a);
    outputs.deinit();

    try client.focus(id);
    try client.setMinimized(id, true);
    try client.setMinimized(id, false);
    try client.setFullscreen(id, true);
    try client.setFullscreen(id, false);
    try client.setGeometry(id, .{ .x = 10, .y = 10, .width = 640, .height = 480 });

    const results = try client.runScript(a, "output_result(1); output_result(2);");
    Client.freeResults(a, results);

    try std.testing.expectError(error.InvalidId, client.focus("nope"));
    try std.testing.expectError(error.WindowNotFound, client.focus("11111111-1111-1111-1111-111111111111"));
    try std.testing.expectError(error.ScriptFailed, client.runScript(a, "nosuchfn();"));
    try std.testing.expectEqualStrings("ReferenceError: nosuchfn is not defined", client.lastError());
}

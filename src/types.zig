//! Windows and screens as kwinctl reports them.
//!
//! Field names match the JSON the KWin scripts produce, which is also what `kwinctl --json`
//! prints. Missing fields take the defaults below.
const std = @import("std");

/// A window as KWin sees it, with its frame geometry in global (all-screens) coordinates.
pub const Window = struct {
    /// KWin's window UUID, e.g. "{04add7fb-72b8-4e58-8ac1-5e22730b907b}".
    id: []const u8 = "",
    title: []const u8 = "",
    /// Window class (resourceClass), e.g. "org.kde.konsole".
    app: []const u8 = "",
    pid: i64 = -1,
    active: bool = false,
    minimized: bool = false,
    fullscreen: bool = false,
    /// False for docks, panels, popups and other special windows.
    normal: bool = true,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// Virtual desktop names; ["*"] when the window is on all of them.
    desktops: []const []const u8 = &.{},
    /// Name of the output (screen) the window is on.
    output: []const u8 = "",

    /// The window's frame (decorations included) as a rectangle.
    pub fn frame(w: Window) Rect {
        return .{ .x = w.x, .y = w.y, .width = w.width, .height = w.height };
    }
};

/// A rectangle in global screen coordinates, in pixels.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

/// One output (monitor).
pub const Screen = struct {
    name: []const u8 = "",
    /// The whole output.
    geometry: Rect = .{},
    /// The part windows maximize into (without panels).
    work_area: Rect = .{},
};

/// Parses JSON from a KWin script into `T`, copying all strings (free with .deinit()).
pub fn parse(comptime T: type, a: std.mem.Allocator, json: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "window JSON fills in defaults for missing fields" {
    const list = try parse([]Window, std.testing.allocator,
        \\[{"id":"{04add7fb-72b8-4e58-8ac1-5e22730b907b}","title":"Konsole","app":"org.kde.konsole","pid":10,
        \\  "active":true,"x":10,"y":20,"width":800,"height":600,"desktops":["Desktop 1"],"output":"Virtual-1","extra":1},
        \\ {"id":"{11111111-1111-1111-1111-111111111111}"}]
    );
    defer list.deinit();
    const first = list.value[0];
    try std.testing.expectEqual(@as(usize, 2), list.value.len);
    try std.testing.expectEqualStrings("org.kde.konsole", first.app);
    try std.testing.expect(first.active);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .width = 800, .height = 600 }, first.frame());
    try std.testing.expectEqualStrings("Desktop 1", first.desktops[0]);
    try std.testing.expectEqual(@as(i64, -1), list.value[1].pid);
}

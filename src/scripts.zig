//! The KWin JavaScript that kwinctl runs.
//!
//! Scripts report with output_result(value) and output_error(text); `wrap` defines both and
//! forwards them to kwinctl over D-Bus. KWin scripts can only answer that way: they have no
//! return value and no access to files or standard output.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("types.zig").Rect;

/// The D-Bus interface scripts call kwinctl back on, with members Result, Error and Done.
pub const reply_interface = "dev.kwinctl.Script";

/// What output_error reports when a window id matches no window.
pub const window_not_found = "kwinctl:not-found";

/// Wraps `source` so it reports to `reply_to` (our bus name), tagging every message with
/// `token` so replies from an older run can't be mistaken for this one. The function wrapper
/// keeps each script's names to itself.
pub fn wrap(a: Allocator, reply_to: []const u8, token: []const u8, source: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\(function () {{
        \\const kwinctlSend = function (kind, value) {{
        \\    callDBus("{s}", "/dev/kwinctl", "{s}", kind, "{s}", String(value));
        \\}};
        \\const output_result = function (value) {{ kwinctlSend("Result", value); }};
        \\const output_error = function (value) {{ kwinctlSend("Error", value); }};
        \\try {{
        \\{s}
        \\}} catch (e) {{
        \\    output_error(String(e));
        \\}}
        \\kwinctlSend("Done", "");
        \\}})();
        \\
    , .{ reply_to, reply_interface, token, source });
}

/// Defines windowInfo(w), which turns a KWin window into the JSON shape of types.Window.
const window_info =
    \\const windowInfo = function (w) {
    \\    const g = w.frameGeometry;
    \\    const desktops = [];
    \\    if (w.onAllDesktops) desktops.push("*");
    \\    else for (let i = 0; i < w.desktops.length; i++) desktops.push(w.desktops[i].name);
    \\    return {
    \\        id: w.internalId.toString(),
    \\        title: w.caption,
    \\        app: w.resourceClass || w.resourceName || "",
    \\        pid: w.pid,
    \\        active: w === workspace.activeWindow,
    \\        minimized: w.minimized,
    \\        fullscreen: w.fullScreen,
    \\        normal: w.normalWindow,
    \\        x: Math.round(g.x), y: Math.round(g.y),
    \\        width: Math.round(g.width), height: Math.round(g.height),
    \\        desktops: desktops,
    \\        output: w.output ? w.output.name : "",
    \\    };
    \\};
    \\
;

/// Normal windows (or every window with `all`), as a JSON array.
pub fn listWindows(all: bool) []const u8 {
    return if (all) list_windows_all else list_windows_normal;
}

const list_windows_normal = list_windows_prefix ++ "const includeAll = false;\n" ++ list_windows_body;
const list_windows_all = list_windows_prefix ++ "const includeAll = true;\n" ++ list_windows_body;
const list_windows_prefix = window_info;
const list_windows_body =
    \\const out = workspace.windowList()
    \\    .filter((w) => !w.deleted && (includeAll || w.normalWindow))
    \\    .map(windowInfo);
    \\output_result(JSON.stringify(out));
;

/// The focused window as JSON, or "null".
pub const active_window = window_info ++
    \\const w = workspace.activeWindow;
    \\output_result(w ? JSON.stringify(windowInfo(w)) : "null");
;

/// Every output with its full geometry and its work area (without panels), as a JSON array.
pub const list_screens =
    \\const rect = (g) => ({ x: Math.round(g.x), y: Math.round(g.y), width: Math.round(g.width), height: Math.round(g.height) });
    \\const out = workspace.screens.map((s) => ({
    \\    name: s.name,
    \\    geometry: rect(s.geometry),
    \\    work_area: rect(workspace.clientArea(KWin.MaximizeArea, s, workspace.currentDesktop)),
    \\}));
    \\output_result(JSON.stringify(out));
;

/// Runs `action` with `w` set to the window with id `id` (already validated by window_id).
pub fn onWindow(a: Allocator, id: []const u8, action: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\const w = workspace.windowList().find((x) => x.internalId.toString() === "{s}");
        \\if (!w) {{
        \\    output_error("{s}");
        \\}} else {{
        \\{s}
        \\}}
    , .{ id, window_not_found, action });
}

/// Actions for onWindow.
pub const Action = struct {
    pub const focus =
        \\if (w.minimized) w.minimized = false;
        \\const onCurrentDesktop = w.onAllDesktops || w.desktops.indexOf(workspace.currentDesktop) >= 0;
        \\if (!onCurrentDesktop && w.desktops.length > 0) workspace.currentDesktop = w.desktops[0];
        \\workspace.activeWindow = w;
    ;
    pub const close = "w.closeWindow();";
    pub const minimize = "w.minimized = true;";
    pub const unminimize = "w.minimized = false;";
    pub const enter_fullscreen = "w.fullScreen = true;";
    pub const leave_fullscreen = "w.fullScreen = false;";

    /// Moves and resizes the frame. KWin 6 ignores a modified copy of frameGeometry assigned
    /// back, so a fresh object is assigned. Wayland apps resize themselves in response, so the
    /// new geometry shows up a moment later.
    /// `buf` must hold geometry_buffer_len bytes.
    pub fn setGeometry(buf: []u8, r: Rect) []const u8 {
        return std.fmt.bufPrint(buf,
            \\if (w.minimized) w.minimized = false;
            \\if (w.fullScreen) w.fullScreen = false;
            \\w.setMaximize(false, false);
            \\w.frameGeometry = {{ x: {d}, y: {d}, width: {d}, height: {d} }};
        , .{ r.x, r.y, r.width, r.height }) catch unreachable;
    }

    /// Big enough for setGeometry with any four i32 values.
    pub const geometry_buffer_len = 256;
};

test "wrapped scripts call back with the token and include the source" {
    const a = std.testing.allocator;
    const js = try wrap(a, ":1.42", "abc123", "output_result(1);");
    defer a.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "callDBus(\":1.42\", \"/dev/kwinctl\", \"dev.kwinctl.Script\", kind, \"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "output_result(1);") != null);
}

test "geometry actions fit their buffer" {
    var buf: [Action.geometry_buffer_len]u8 = undefined;
    const body = Action.setGeometry(&buf, .{ .x = std.math.minInt(i32), .y = std.math.minInt(i32), .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) });
    try std.testing.expect(std.mem.indexOf(u8, body, "w.frameGeometry = { x: -2147483648") != null);
}

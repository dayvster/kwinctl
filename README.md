# kwinctl

List and control KDE Plasma 6 windows from the command line or from Zig.

On Wayland, KWin only lets its own scripts see windows. kwinctl writes a small KWin script, runs
it over D-Bus and reads the answer back. It's written in plain Zig with its own minimal D-Bus
client: no libdbus, no libc, no Qt, a single static binary of about 250 KB.

## Install

```sh
zig build -Doptimize=ReleaseSmall
cp zig-out/bin/kwinctl ~/.local/bin/
```

Needs Zig 0.17 to build, and KDE Plasma 6 (KWin) to run. Linux only.

## Usage

```sh
kwinctl list                    # id, app, title (tab-separated)
kwinctl list --all              # also panels, docks and popups
kwinctl active                  # the focused window
kwinctl screens                 # outputs with their full and usable areas
kwinctl focus ID                # un-minimizes and switches desktop if needed
kwinctl close ID
kwinctl minimize ID             # unminimize ID restores
kwinctl fullscreen ID on|off
kwinctl move ID X Y W H         # move and resize
kwinctl script FILE             # run your own KWin script ("-" reads stdin)
```

Add `--json` before the command for JSON output (every window field: geometry, pid, desktops,
output, state), and `--timeout MS` to change the 5 second limit.

IDs are KWin's window UUIDs, with or without braces:

```sh
kwinctl focus "$(kwinctl list | grep -i firefox | cut -f1 | head -1)"
```

### Your own scripts

Inside a script, `output_result(value)` prints a line and `output_error(text)` fails with that
message. A thrown exception is reported the same way.

```sh
echo 'output_result(workspace.currentDesktop.name);' | kwinctl script -
```

## As a Zig library

```zig
// build.zig.zon: .kwinctl = .{ .url = "git+https://github.com/dayvster/kwinctl#<commit>", .hash = ... }
// build.zig:     exe.root_module.addImport("kwinctl", b.dependency("kwinctl", .{}).module("kwinctl"));
const kwinctl = @import("kwinctl");

var client = try kwinctl.Client.init(gpa, .{
    .bus_address = bus_address,   // $DBUS_SESSION_BUS_ADDRESS
    .runtime_dir = runtime_dir,   // $XDG_RUNTIME_DIR, where script files are written
});
defer client.deinit();

const windows = try client.windows(gpa, .{});
defer windows.deinit();
for (windows.value) |w| std.debug.print("{s} {s}\n", .{ w.app, w.title });
try client.focus(windows.value[0].id);
```

Also: `activeWindow`, `screens`, `close`, `setMinimized`, `setFullscreen`, `setGeometry` and
`runScript`. On errors, `client.lastError()` has KWin's message.

## How it works

1. Connect to the session bus (EXTERNAL auth) and get a unique name.
2. Write the script to `$XDG_RUNTIME_DIR/kwinctl-PID-N.js` (mode 0600), wrapped so its
   `output_result` calls go back to that unique name through KWin's `callDBus`.
3. `org.kde.kwin.Scripting.loadScript`, then `run` on `/Scripting/ScriptN`.
4. Collect the replies until the script reports it is done, then unload it and delete the file.

Window IDs are validated as UUIDs before they are put into a script.

## Tests

```sh
zig build test                                # unit tests (D-Bus encoding, ids, JSON)
zig build && tests/run-headless.sh tests/e2e.sh   # against a real headless KWin
```

The end-to-end test starts `kwin_wayland --virtual` on a private D-Bus session with a scrubbed
environment, opens Konsole and KWrite in it and drives them with kwinctl. Nothing touches your
running desktop.

## License

MIT

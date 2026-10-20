# CDP library

Import the public `cdp` module. Use `cdp.journey` for an owned browser and page
actions; use `CdpClient` and `WsSession` for an existing loopback CDP endpoint.
The [complete example](../examples/smoke.zig) runs without a web server.

## Package integration

Add a local path dependency to your package's `build.zig.zon`:

```zig
.dependencies = .{
    .zig_cdp = .{ .path = "../zig-cdp" },
},
```

In `build.zig`, attach the module to a native executable or test:

```zig
const browser = b.dependency("zig_cdp", .{
    .target = b.graph.host,
    .optimize = optimize,
});
exe.root_module.addImport("cdp", browser.module("cdp"));
```

The dependency uses the sibling `zig-process` repository. Both packages use the
compiler pinned in `.zigversion`; the module honors the requested optimization.

## Launch and cleanup

```zig
const std = @import("std");
const J = @import("cdp").journey;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const browser = try J.Browser.start(arena.allocator(), init.io);
    defer browser.stop();
    const page = try browser.page(&.{"http://127.0.0.1:4180"});
    defer page.close();
    try page.goto("http://127.0.0.1:4180/");
    try page.screenshot("screen.png");
}
```

Start the application's server separately. The default launcher searches
`/usr/bin/google-chrome`, `/usr/bin/google-chrome-stable`, `/usr/bin/chromium`,
then `/usr/bin/chromium-browser`. Use
`Browser.startWithOptions(a, io, .{ .executable = "/path/to/chrome", .headless = false })`
to select another executable or open a visible browser. Headed mode needs a
working graphical session. The normal browser sandbox remains enabled.

By default each browser owns a new private profile, ephemeral debug port, and
process group. Set `Options.user_data_dir` to an existing unlocked user-data
directory to preserve it across runs. The supplied directory is never deleted;
private download staging and other temporary files use a separate workspace.
Locks are rejected without removal. Startup checks a fresh debugging endpoint
and the launched child's profile lock before connecting.

`browser.page(origins)` creates an isolated context in either mode.
`browser.profilePage(origins)` instead reuses a blank tab in the default context
(or creates one if none exists), sharing the profile's cookies and local storage.
Closing this page detaches; stopping the browser closes the owned process.
The CLI uses this method when `--user-data-dir` is supplied.

Close pages, stop the browser, then destroy the arena, in that order.
`stop()` is idempotent. It bounds the graceful
protocol close and process wait separately to two seconds each, then force-cleans
the owned process group and joins the exact child. The library does not install
signal handlers or subreaper policy and never reaps unrelated children.

Returned journey strings, JSON values, locators, and request records borrow from
the arena. Keep the origin list alive while its page is open. Copy values needed
after destroying the arena. Journey storage accumulates until arena destruction;
use finite sessions. Use one task per connection.

## Origins and navigation

Origins contain a scheme, host, and port, with no path or trailing slash. Include
all application, API, asset, and redirect origins. `localhost` and `127.0.0.1`
are different origins. Intercepted requests outside the list are blocked.
`about:blank`, `data:`, and `blob:` are allowed; `browser.page(&.{})` is useful for
in-memory fixtures. Page interception is not a process-wide network sandbox.

`page.goto(url)` and `reload()` wait for a new document to finish loading. Wait
separately for the application to become ready. The default viewport is 1280 ×
720 and the default page timeout is 30 seconds; set `page.timeout_ms` as needed.
`initScript(source)` registers JavaScript for subsequent documents.

## Actions and evaluation

| Action | Example |
| --- | --- |
| Fill | `try page.label("Name").fill("Sample");` |
| Click | `try page.role(.{ .role = "button", .name = "Save" }).click();` |
| Scope | `try page.css("#settings").role(.{ .role = "button", .name = "Save" }).click();` |
| Read text | `const text = try page.css("#status").innerText();` |
| Wait | `try page.text("Saved").waitVisible();` |
| Checkbox | `try page.label("Enabled").checked(true);` |
| Select | `try page.label("Theme").select("dark");` |
| Enter | `try page.label("Search").pressEnter();` |
| Upload | `try page.css("input[type=file]").file("/absolute/input.csv");` |
| Screenshot | `try page.screenshot("screen.png");` |

Actions generally require exactly one match; scope ambiguous locators or use
`first()`/`nth(index)` intentionally. Clicks scroll into view and check visibility,
enabled state, hit testing, and stable geometry before sending mouse input.
`fill()` sends browser text input. `select()` assigns a value and dispatches DOM
events. File controls may be hidden but must be enabled. Role/name matching is
a bounded helper, not a complete accessibility-name implementation.

`page.eval(expression)` awaits promises and returns `std.json.Value`.
`page.evaluate(function, argument)` serializes a Zig argument into a JavaScript
function call. `J.field`, `J.str`, `J.boolean`, and `J.number` inspect JSON, with
fallback values for missing/incompatible types. Check tags when that distinction
matters. `locator.handle()` retains a real DOM element for identity checks.
`page.command()` and `browser.command()` expose additional CDP methods.

## Responses and downloads

Call `mark()` before an action, then wait for the observed request:

```zig
const mark = try page.mark();
try page.role(.{ .role = "button", .name = "Save" }).click();
const response = try page.response(.{
    .after = mark,
    .method = "POST",
    .path = "/api/items",
});
if (response.failed or response.status != 200) return error.SaveFailed;
const bytes = response.body orelse return error.ResponseBodyUnavailable;
_ = bytes;
```

Path matching excludes query strings. `responseAny()` accepts several matches.
`response.header(name)` performs case-insensitive response-header lookup.
Captured URLs, bodies, and headers may contain credentials; redact reports.

`page.download(control, output_path)` clicks the supplied locator, waits for a
completed download, writes the bytes, and returns JSON with `filename` and `csv`
fields. `csv` is the current content key. The download read limit is 20 MiB.
Create output directories beforehand. Relative paths use the caller's working
directory; existing files are overwritten. Outputs outside the browser profile
survive shutdown and belong to the caller.

## Existing browser and raw protocol

`CdpClient.init(a, io, port)` addresses `127.0.0.1`. `newTarget("about:blank")`
returns an owned `Target`; connect with `connectWs(target.web_socket_debugger_url)`.
Close the session, close only the target you created, and call `target.deinit(a)`.
For `listTargets()`, deinitialize each item and free the returned slice.

`WsSession.call()` and `evaluate()` return allocated raw replies; free them with
the session allocator. `evaluateJson()` returns an owned parsed reply; call its
`deinit()`. These include the full CDP result/error envelope. `takeEvent()`
transfers an allocated event to the caller. Raw connections neither own the
browser process nor install journey interception and locator behavior.

## Errors and limits

`NoBrowserFound` means no default executable was found. `BrowserExited` or
`BrowserLaunchTimeout` requires checking the executable, sandbox, and writable
`/tmp`; browser stderr is currently suppressed. `ElementNotActionable` reports
ambiguous, covered, hidden, or disabled controls. `BrowserEvaluationFailed`
reports a JavaScript exception. Explicit navigation/reload accepts `beforeunload`;
other native dialogs are dismissed and fail with `UnexpectedBrowserDialog`.

Frames and retained wire messages are bounded to 64 MiB; pending messages to
8,192; observed requests to 20,000. Socket reads have a 30-second timeout.
Numeric reply IDs are parsed structurally, with interleaved events retained.
A failed wire connection must be closed rather than reused. Only the exact stale
interception cancellation error is ignored. The tests cover finite input,
upload/download, isolation, and cleanup cases; they do not prove every protocol
fault, browser version, or application workflow.

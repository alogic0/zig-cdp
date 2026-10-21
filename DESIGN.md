# zig-cdp design

Provide a native Zig CDP library and a reusable command-line browser controller.
Linux and the compiler pinned in `.zigversion` are the initial supported target.
The package has no GUI framework or application dependency. `zig-process` supplies
exact-child and owned-process-group lifecycle management through a pinned GitHub
dependency with a content hash. The package exports the `cdp` module and installs
`zig-cdp`.

## Library ownership

The protocol and journey layers originate in zg-gui's native browser tooling.
The protocol layer exposes `CdpClient`, `WsSession`, and `Target`; callers may
connect to an existing loopback CDP endpoint without owning its process.
`journey.Browser` owns a private temporary workspace, ephemeral loopback debug
port, and one browser process group. By default the workspace is also its fresh
profile. An explicitly supplied existing user-data directory remains caller
owned and is never deleted, including on startup failure. Download staging stays
in the workspace. It uses `zig-process` for launch and cleanup. It never changes
process-wide signal or subreaper policy.

`Browser.start` uses default launch options. `startWithOptions` additionally
accepts an explicit executable, headed/headless mode, and `user_data_dir`.
Existing profile locks are rejected without modification. Before connecting,
require a new DevToolsActivePort record and a profile lock naming the launched
child; connect to that record's browser WebSocket path. A stale record must not
attach to or close another process. Close pages before stopping their browser;
then destroy the journey arena. `page` owns an isolated context; `profilePage`
uses the default context and reuses a startup blank tab when present. Its close
detaches without disposing the default context. Both retain an exact origin
allowlist supplied by the caller.
Journey results borrow arena storage. Socket use is serialized by the caller.
Graceful shutdown requests browser closure and waits up to two seconds; fallback
cleanup joins the exact child and terminates its owned process group before
removing the temporary workspace. Calling stop again is harmless.

Protocol frames and queued messages are bounded; malformed replies and wire
failures seal the affected connection. The initial extraction retains the finite
behavior and limits documented in the library guide. It does not claim exhaustive
CDP, accessibility, browser-version, or cross-engine compatibility.

## CLI session owner

`zig-cdp --session PATH serve` exclusively creates a private session directory
and listens on its Unix socket. It stays in the foreground and owns one browser
and browser context, with one selected page. Independent CLI calls use
`--session PATH` to address that selection.
Multiple sessions use distinct directories and processes. No detached daemon,
global service, fixed TCP control port, or saved user browser profile is needed.
`--user-data-dir` explicitly selects an existing profile and its default context
instead of the isolated context. Cookies/storage then survive session restarts.
The CLI controls the startup tab without creating another incognito window.
Readiness/status expose the profile, persistence flag, and selected debug port.
Headless pages keep deterministic 1280 × 720 device metrics. Headed pages leave
metrics to Chrome so the viewport and display scale follow the actual window.

The session directory must not already exist. Refuse collisions rather than
deleting another owner's state. On normal close, idle expiry, SIGINT, or SIGTERM,
close the browser and remove only this session's socket and directory. Signal
handling belongs only to the executable. SIGKILL and machine failure cannot run
cleanup; a stale directory requires explicit inspection/removal by its owner.

One newline-delimited JSON request and reply travel over each local connection.
Requests contain a command and string arguments. Replies distinguish success
from failure; CLI failures exit nonzero. Bound request/response bytes, socket
read time, and idle duration. Commands run serially. Broken browser connections
require a new session; ordinary locator or evaluation errors can be corrected.
The same owner services events for every attached page between commands. Accept
results retain their resource owner even when arrival races a timer or shutdown.
The session arena retains browser observations until session exit; this first
version is for finite automation sessions, not indefinite daemon workloads.

Supported operations cover status, origins, navigation, reload, setting fixture
HTML, JavaScript evaluation, CSS-based click/fill/text/wait/upload/download,
screenshots, tab management, and close. File paths resolve in the client's
working directory.
Origins are explicit CLI policy and may be extended during a session. Workflow
assertions, credential handling, and reports remain with the caller.

Tab commands use stable CDP target IDs and stay within the initial context.
Listing excludes internal browser targets and other contexts. New tabs share
cookies/storage and are attached before navigation; switching retains each
page's connection, DOM state, and interception. The CLI owns selection separately
from desktop focus. Origins and timeout settings apply across controlled tabs.
Closing a tab detaches its connection without disposing the context. Closing the
last tab creates a blank replacement before closing it. Externally closed tabs
are reconciled against Chrome's target list, and selection recovers to a survivor.
Browser shutdown remains the final context/process cleanup owner.

The library exposes context-scoped `tabs`, `newTab`, and `attachTab`, plus target
closure and connection-only `Page.detach`. Only a Page created by `Browser.page`
owns its isolated context. Borrowed sibling/attached pages never dispose it.

## Agent command layer

The public `agent.Page` borrows a page WebSocket and uses a request allocator.
It does not launch or stop a browser, install interceptors, change metrics, or
configure downloads. It obtains role/name matches from Chrome's accessibility
tree. CSS and exact normalized text are alternative strict locators. Temporary
remote objects belong to a unique command group released on completion.

CLI requests retain their command/argument fields and add optional typed
locators, tab IDs, output bounds and per-command budgets. Existing positional
commands remain accepted. Errors retain `err` and add structured phase,
match-count and action-progress details. Progress describes dispatch, not
application-level success; consumers verify the effect of an action.

All frames in an operation share an absolute read deadline. Locator polling
allows at most 100 ms for the last in-flight RPC to finish before abandoning
the connection; remote-object cleanup has a separate 200 ms allowance. A
transport failure seals the connection, while ordinary locator errors do not.

## Delivery and verification

First establish the standalone library with its existing real-browser fixtures,
a compiled example, and an independent package consumer. Then add the CLI with
end-to-end checks across separate command processes: shared state, actual input,
navigation, screenshot bytes, uploads/downloads, errors, isolation, bounded
framing, session collisions, and cleanup through close/signals/idle expiry.
Run relevant checks in Debug and ReleaseSafe. Existing consumers remain intact;
their migration and acceptance are separate work.

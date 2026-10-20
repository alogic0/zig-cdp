# zig-cdp design

Provide a native Zig CDP library and a reusable command-line browser controller.
Linux and the compiler pinned in `.zigversion` are the initial supported target.
The package has no GUI framework or application dependency. `zig-process` supplies
exact-child and owned-process-group lifecycle management through a sibling path
dependency. The package exports the `cdp` module and installs `zig-cdp`.

## Library ownership

The protocol and journey layers originate in zg-gui's native browser tooling.
The protocol layer exposes `CdpClient`, `WsSession`, and `Target`; callers may
connect to an existing loopback CDP endpoint without owning its process.
`journey.Browser` owns a fresh profile, ephemeral loopback debug port, and one
browser process group. It uses `zig-process` for launch and cleanup. It never
changes process-wide signal or subreaper policy.

`Browser.start` uses default launch options. `startWithOptions` additionally
accepts an explicit executable and headed/headless mode. Close pages before
stopping their browser; then destroy the journey arena. Pages own isolated
browser contexts and retain an exact origin allowlist supplied by the caller.
Journey results borrow arena storage. Socket use is serialized by the caller.
Graceful shutdown requests browser closure and waits up to two seconds; fallback
cleanup joins the exact child and terminates its owned process group before
removing the profile. Calling stop again is harmless.

Protocol frames and queued messages are bounded; malformed replies and wire
failures seal the affected connection. The initial extraction retains the finite
behavior and limits documented in the library guide. It does not claim exhaustive
CDP, accessibility, browser-version, or cross-engine compatibility.

## CLI session owner

`zig-cdp --session PATH serve` exclusively creates a private session directory
and listens on its Unix socket. It stays in the foreground and owns one browser
and page. Independent CLI calls use `--session PATH` to address that same page.
Multiple sessions use distinct directories and processes. No detached daemon,
global service, fixed TCP control port, or saved user browser profile is needed.

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
The same owner services browser events between commands. Accept results retain
their resource owner even when arrival races a timer or shutdown.
The session arena retains browser observations until session exit; this first
version is for finite automation sessions, not indefinite daemon workloads.

Supported operations cover status, origins, navigation, reload, setting fixture
HTML, JavaScript evaluation, CSS-based click/fill/text/wait/upload/download,
screenshots, and close. File paths resolve in the client's working directory.
Origins are explicit CLI policy and may be extended during a session. Workflow
assertions, credential handling, and reports remain with the caller.

## Delivery and verification

First establish the standalone library with its existing real-browser fixtures,
a compiled example, and an independent package consumer. Then add the CLI with
end-to-end checks across separate command processes: shared state, actual input,
navigation, screenshot bytes, uploads/downloads, errors, isolation, bounded
framing, session collisions, and cleanup through close/signals/idle expiry.
Run relevant checks in Debug and ReleaseSafe. Existing consumers remain intact;
their migration and acceptance are separate work.

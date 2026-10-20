# Current delivery

Initial standalone extraction and command-line wrapper, October 20, 2026.

Acceptance scope:

- Standalone `cdp` package with no GUI-framework dependency.
- Fresh-profile browser launch and exact owned-process cleanup.
- Runnable Zig example and independent package import.
- Persistent CLI session with separate commands sharing page state.
- Navigation, actual input, evaluation, screenshots, uploads, and downloads.
- Explicit origins, meaningful nonzero errors, and bounded local transport.
- Session isolation, collision rejection, close/signal/idle cleanup.
- Debug/ReleaseSafe checks, formatted sources, reviewed commits.

## Standalone library

Implemented the `cdp` package, copied the protocol/locator/journey basis, and
replaced the owned browser's process management with `zig-process`. The package
offers explicit executable/headed options and idempotent stop. Raw evaluation
now JSON-escapes all control characters and parsed replies retain owned strings.
The obsolete launcher using the default user profile is not exported here.

| Check | Result |
| --- | --- |
| `zig build test check example --summary all`, Debug and ReleaseSafe | 8/8 tests and the complete example passed; 7/7 steps each |
| `zig build test --summary all` in `tests/package`, both profiles | 1/1 independent-consumer test passed; 3/3 steps each |
| Zig formatting and diff checks | Passed |

Checks include actual input, file upload/download, context isolation, origin
denial, stale interception recovery, owned-profile removal, repeated stop,
unrelated-child preservation, and parsed response ownership. Browser checks used
Chrome 155.0.8059.84. They do not establish application acceptance.

## CLI wrapper

Implemented `zig-cdp serve` and client commands over a private Unix socket.
Separate client processes share the owned browser page. Commands cover origins,
navigation/reload, fixture HTML, evaluation, clicks/fill/text/waits, screenshots,
uploads, downloads, status, and close. Inputs/outputs are JSON with explicit
failure exit status. File paths resolve in the client. Idle browser events are
serviced by the same serialized owner. SIGINT/SIGTERM handling stays in the CLI.

| Check | Result |
| --- | --- |
| `zig build test-cli --summary all` | Passed against actual Chrome, Debug |
| Same command with `-Doptimize=ReleaseSafe` | Passed against actual Chrome |
| `zig build test-cli test check example -Doptimize=ReleaseSafe --summary all` | 10/10 steps; library tests reused passing results, CLI and example executed |
| Format, documentation links, and diff checks | Passed |

The final CLI checks cover shared DOM state, trusted input events, independent
sessions, actual local HTTP navigation/reload, background HTTP requests between
commands, PNG output, exact upload/download bytes, and client-relative paths.
Negative cases cover malformed/oversized requests, oversized replies, invalid
origins/arguments, disabled controls, timeouts, JavaScript exceptions, recovery,
directory collisions, missing executables, and early browser exit. Close, idle
expiry, and SIGINT/SIGTERM during work remove the session directory and browser
profile and leave the owned browser PID absent. Closing one session leaves its
peer usable. These are finite interface checks, not every transport fault.

Delivery is complete for Linux headless sessions with the pinned compiler.
Headed-window behavior, cross-engine support, indefinite session memory growth,
SIGKILL recovery, publication, and consumer migration remain outside this scope.
Both original repositories remain unchanged by this delivery.

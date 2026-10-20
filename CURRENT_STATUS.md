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

The initial delivery covered Linux headless sessions with the pinned compiler.
Cross-engine support, indefinite session memory growth, SIGKILL recovery,
publication, and consumer migration remain outside this scope.
Both original repositories remain unchanged by this delivery.

## Agent README workflow

The README now has a direct shell-tool workflow: retain the session owner, wait
for its readiness record, preserve absolute paths across fresh tool calls,
inspect bounded DOM data, act with observed CSS selectors, verify JSON results,
capture a screenshot, and close/join the owner. Corrected the argument order in
the design document to match the CLI.

Executed all five README command blocks verbatim using separate shells with
Debug and ReleaseSafe binaries. Both runs verified discovered controls, input
and click effects, the expected text result, PNG bytes, and removal of the owned
session/profile/process. Documentation links and diff checks passed.

## Existing profiles

Added CLI `serve --user-data-dir PATH` and library `Options.user_data_dir` for
an existing unlocked Chrome profile. The CLI uses `profilePage` to control the
startup tab in the default context, preserving cookies and local storage and
avoiding an extra incognito window. Isolated `page` behavior remains available.
Readiness/status include the selected free CDP port and profile mode.

Caller profile ownership is separate from private workspace/download staging.
Close, signals, and launch failures never delete the supplied directory. Startup
rejects existing locks without altering them, ignores a stale endpoint record,
and verifies the new endpoint against the launched child's Chrome profile lock.

Verification with Chrome 155.0.8059.84:

- Debug: `zig build test test-cli check --summary all`, 8/8 steps and 9/9 tests.
- ReleaseSafe: `zig build test test-cli check example install
  -Doptimize=ReleaseSafe --summary all`, 12/12 steps and 9/9 tests.
- CLI checks proved cookie/local-storage persistence across restarts, one startup
  page, busy/stale-lock rejection, stale-endpoint and unrelated-process
  preservation, download output, profile files surviving close/SIGTERM/failures,
  and normal cleanup of temporary profiles. The library check also verified
  workspace removal and choosing the default tab alongside an isolated context.
- Opened the requested application in a visible X11 window using the user's
  supplied profile. Verified one page/one window, completed navigation, CLI
  evaluation, and a new loopback-only debugging port. Left this session open as
  requested. This is one real headed-session check, not general desktop coverage.

## Headed viewport correction

Headed pages previously inherited the headless 1280 × 720 device-metrics
override, leaving unused space in larger windows. Browser launch mode now
controls this override: headed pages use Chrome's native viewport and display
scale; headless pages retain the fixed dimensions.

Added `test-headed`, which uses a separate Xvfb display and removes inherited
Wayland selection. Its real-browser regression resizes default-context and
isolated-context windows twice and checks that the content dimensions follow
both width and height changes. It failed before the fix and passed afterward.
The existing headless fixture also verifies its 1280 × 720 dimensions.

- Debug `zig build test-headed test check --summary all`: 9/9 build steps,
  9/9 library tests and 1/1 headed regression passed.
- ReleaseSafe with the same steps plus `install`: 11/11 build steps,
  9/9 library tests and 1/1 headed regression passed.
- Removed the live page's override through CDP without restarting the browser.
  Its viewport changed from 1280 × 720 to the actual 1919 × 992 content area.
  The existing profile, window, and debugging port remain in use.

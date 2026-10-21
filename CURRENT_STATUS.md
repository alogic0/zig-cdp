# Current delivery

## Low-core session scheduling, October 21, 2026

The first hosted CLI checks exposed a timeout on the initial session `status`
command. It reproduces locally with two CPUs: the pinned I/O runtime may run
`async` tasks inline when its worker pool is full, preventing a competing task
from starting. Session/signal, accept/tick, command/deadline and borrowed-endpoint
races now require concurrent scheduling. Graceful browser closure also races its
deadline concurrently and joins admitted work before fallback process cleanup.
No public API, ownership policy or acceptance threshold changes.

The full CLI suite, ten library tests, example and headed Xvfb check pass in
Debug with two CPUs and ReleaseSafe with one CPU. All six CLI groups pass;
descriptors remain seven. CI now runs the complete CLI suite with one CPU in
both profiles so additional runner cores cannot hide this regression.

The hosted single-CPU CLI checks pass both modes. A subsequent Debug headed
resize assertion failed. The headed fixture now activates each document before
observing its viewport and reports native bounds, visibility, scale and page
geometry on failure. Its existing size tolerances and three-second deadline
are unchanged; the focused headed check passes locally in both modes.
Hosted diagnostics still showed a 900×700 native window with the preceding
1100-pixel viewport. CI now requests an owned Openbox window manager inside
Xvfb through `-Dheaded-window-manager=true`; local bare-Xvfb checks remain
available. The window manager is terminated and joined after the test.
The headed fixture also renders actual responsive content, requires document
focus and brings the page forward after each native resize; it does not measure
an idle blank document. Its existing geometry assertions remain intact.

A later hosted external-browser fixture observed an empty DevToolsActivePort
file between creation and its record write. The fixture now polls for a valid
port and browser path while retaining its exact child and the original ten-second
budget. Focused endpoint acceptance passes both profiles with one CPU.

Click stability sampling also preserves `ElementNotStable` if its budget expires
between the first point observation and the comparison delay. It previously
leaked a generic `Timeout` at that boundary. Input remains undispatched;
cancellation stays distinct. Agent and borrowed-endpoint acceptance pass both
profiles with one CPU and the original 350 ms moving-control budget.

CI also tests the exact bundled HTTP 0.2.1 and support 0.1.0 archives in both
profiles, including examples and isolated consumers with empty package caches.
All four provider jobs passed the first hosted run; its two CLI failures are
retained as failures. The CDP package consumer now builds from an exported source
tree and a fresh cache. Per-commit hosted results are available in
[GitHub Actions](https://github.com/alogic0/zig-cdp/actions?query=branch%3Apublication-checks).

## Native CLI acceptance migration completed, October 21, 2026

`zig build test-cli` now runs the native Zig subprocess suite. The Python runner
and CI interpreter check are removed. All prior scenarios are mapped in the
[migration record](docs/plans/2026-10-21-native-cli-migration.md); Python/native
parity was established against identical Debug and ReleaseSafe CLI artifacts
before removal. Production sources and public CDP imports are unchanged.

Test-only dependencies pin HTTP 0.2.1 and test-support 0.1.0 as immutable bundled
archives, sharing the existing process 0.5.1 identity. Fixtures retain independent
browser ownership, private workspaces, dynamic ports, bounded commands and joined
HTTP handlers. CLI failures retain bounded scenario/command diagnostics.

Verification with Zig 0.17.0 and Chrome 155.0.8059.84:

| Check | Debug | ReleaseSafe |
| --- | --- | --- |
| Complete native CLI suite | 6/6 groups passed | 6/6 groups passed |
| Library tests, fresh isolated cache | 10/10 passed | 10/10 passed |
| Independent exported package consumer | 1/1 passed | 1/1 passed |
| Headed Xvfb regression | 1/1 passed | 1/1 passed |
| Example, CLI installation and standard combined command | 16/16 build steps passed | 16/16 build steps passed |
| Resource owner RSS bytes | 8,511,488 → 8,605,696 | 3,100,672 → 3,497,984 |
| Resource owner descriptors | 7 → 7 | 7 → 7 |

The workload remains 24 warmup commands, 720 inspection/evaluation commands and
36 tab cycles, with RSS growth below 32 MiB and descriptors at most baseline+3.
Both streaming failures cancel transfer, clear staging and preserve recovery.
Browser/profile ownership, saved state and unrelated tabs survive the required
error and signal cases. Format, relative documentation targets and diff checks
pass. The active build/test sources invoke no Python. Native acceptance always
executes even when its compiler artifacts are cached.

## Agent usability plan completed, October 21, 2026

Version 0.2.0 implements all six stages of the saved
[agent usability plan](docs/plans/2026-10-21-agent-usability.md): bounded read and
Chrome accessibility snapshots, strict semantic locators, interaction commands,
short-lived attachment to existing browsers, structured command diagnostics and
shared timeout budgets, reclaimable session storage, and real-browser workflows
in both ownership modes. Existing positional commands remain accepted.

The CLI retains at most 64 controlled pages and 128 origins. Inspection/results
expire per request; detached pages release their arenas. CLI policy events do
not retain network bodies or exception histories. Explicit downloads have
bounded event/output capture and owned staging cleanup. Journey library callers
retain their existing observation defaults and can allocate individual tab
connections separately. Browser process/signal ownership remains unchanged.

The resource regression runs 720 inspection/evaluation commands and 36 tab
cycles after warmup, checks owner RSS growth below 32 MiB and stable descriptor
counts, verifies repeated download staging cleanup and origin limits, and kills
its own test browser during a pending command. The final CLI runs measured
8,168 to 8,260 KiB RSS in Debug and 3,344 to 3,372 KiB in ReleaseSafe, with seven
descriptors throughout. This bounds tested owner behavior, not
Chrome's application memory or indefinite process lifetime.

Verification used the pinned Zig 0.17.0 and Chrome 155.0.8059.84:

| Check | Debug | ReleaseSafe |
| --- | --- | --- |
| `test test-cli check example install test-headed` | 15/15 build steps; 10/10 library tests; 1/1 headed test | Same |
| Independent package consumer | 1/1 passed | 1/1 passed |
| CLI workflows | Owned and external browsers passed | Same |
| Resource regression | 720 commands, 36 tab cycles; stable descriptors | Same |
| Discovery faults and browser exit | Passed | Passed |
| Format, relative documentation links, diff and private-path checks | Passed | Passed |

The final CLI cases also cover moving controls, hidden/read-only inputs, shifted
keyboard input, oversized response diagnostics, and explicit navigation/reload
on borrowed tabs. Streaming download fixtures verify that timeout and size
failures cancel transfers, remove staging, and leave the session usable.
CI already runs these expanded fixtures in both profiles.
Iframe/shadow-root traversal, batching and MCP remain deferred as planned.

## Existing-browser attachment, October 21, 2026

Added loopback HTTP/browser-WebSocket endpoint commands and the public
`agent.Connection` API. Page commands require explicit target IDs. Disconnect,
command interruption and errors preserve the external browser, profile,
unrelated tabs and native viewport. Download capture is scoped to an explicit
command; normal attachment installs no interceptors or persistent helpers.
HTTP discovery and WebSocket upgrades validate protocol replies.

The real-browser CLI suite passes in Debug and ReleaseSafe in both owned and
external modes, covering semantic inspection/actions, HTTP and blob downloads,
explicit targets, timeout recovery, SIGINT/SIGTERM and ownership preservation.
The independent consumer also checks the public borrowed-connection API.


## Agent inspection and interactions, October 21, 2026

Implemented the first two stages of the agent-usability plan: bounded UTF-8
text and Chrome accessibility snapshots; strict CSS, exact text and actual
Chrome role/name locators; select, keyboard and locator-state waits; file/stdin
values and scripts; explicit viewport/full-page screenshots. Positional commands
remain supported. Errors add phase, match-count and input-dispatch details.

The public agent.Page command layer borrows a socket and releases its temporary
remote objects. Command frame reads share a deadline, with bounded allowances
for the final polling RPC and remote-object cleanup. Cancellation still joins
and cleans owned browser sessions.

Debug and ReleaseSafe pass the full CLI suite, including new real-browser
semantic actions, disabled/covered/ambiguous controls, contenteditable and
trusted input, hidden uploads, downloads, Unicode and output bounds. Both modes
also pass 9/9 existing library tests and the independent consumer, which now
uses the public agent API. Existing-profile and signal-cleanup checks pass.
Existing-browser attachment and resource/deadline completion are recorded above.

## Publication preparation, October 21, 2026

Version 0.1.0 now carries an MIT license credited to zig-cdp developers.
The package includes the license and fetches zig-process from public GitHub
revision `4826a4973b20b65ded5f0fb79d5eb49694024398`, pinned by content hash.
Installation and library integration guides use `alogic0/zig-cdp`; a sibling
process repository is no longer required. Generated dependency directories are
ignored alongside build caches.

GitHub Actions covers Ubuntu Debug and ReleaseSafe with the pinned compiler,
Chrome, Python 3, and Xvfb. Checkout and toolchain setup actions use exact
release commits, read-only repository permissions, and separate matrix cache
keys. Pushes, pull requests, and manual dispatch run the same checks.

Verification used an isolated source export without a sibling checkout and an
initially empty global Zig cache, with Chrome 155.0.8059.84:

| Check | Result |
| --- | --- |
| `zig build test check example install`, both profiles | 9/9 library tests, example and CLI build; 10/10 steps each |
| `zig build test-cli`, both profiles | Full CLI acceptance suite passed; 3/3 steps each |
| `zig build test-headed`, both profiles | 1/1 headed regression; 3/3 steps each |
| `zig build test` in `tests/package`, both profiles | 1/1 consumer test; 3/3 steps each |
| Workflow lint | actionlint 1.7.12 passed |
| Package export | 22 files, including LICENSE; build caches and Git metadata excluded |
| Formatting, relative documentation links, and diff checks | Passed |

The six original commits and all stored historical blobs were scanned for
obvious credentials, private absolute paths, and local-file links; none were
found. These are local publication checks; the first GitHub-hosted CI run follows
publication of the repository.

## Initial delivery

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

## CLI tab management

Added `tabs`, `new-tab [URL]`, `switch-tab ID`, and `close-tab [ID]`. Replies use
stable target IDs, titles, URLs, and an explicit CLI selection; `status` includes
`tab_id`. Tabs share the session's initial context and cookies/storage. Page
commands follow the selected tab without reloading other documents. Context
scope excludes browser UI, workers, and other contexts/sessions.

The library now exposes tab listing, creation, attachment, and target closure.
Borrowed tab connections do not dispose shared contexts, and `Page.detach`
explicitly releases just a connection. The CLI retains attached pages, applies
origins/timeouts across them, pumps them between commands, and reconciles tabs
closed externally. Closing the final tab creates a blank replacement before
removing the old one; `close` retains its whole-session meaning. Commands remain
serial, so other pages are serviced between long-running commands.

Verification with the pinned compiler and Chrome 155.0.8059.84:

- Debug `test-cli` passed; `test-headed test check` passed (9/9 build steps,
  9/9 library tests and 1/1 headed test).
- ReleaseSafe `test-cli test-headed test check install` passed (13/13 build
  steps, 9/9 library tests and 1/1 headed test).
- CLI tests cover both temporary and saved-profile modes: tab identity and
  selection, preserved form values, shared cookies/storage, optional URL and
  blank creation, origin denial without creating a tab, invalid arguments/IDs,
  context exclusion, externally opened/closed tabs, inactive background requests,
  inactive/selected/final-tab closure, screenshots, and session cleanup.
- The headed Xvfb regression verifies new tabs use the same context window,
  retain native viewport sizing, and preserve document state after reattachment.
- Used the installed executable directly across fresh shell calls to list,
  create, switch, inspect, and close tabs. The demo owner exited cleanly and its
  browser/profile/session were removed. No helper script was needed for control.

The executable and guides are updated. Existing `serve` owners retain their old
code and require a restart to use the new tab commands.

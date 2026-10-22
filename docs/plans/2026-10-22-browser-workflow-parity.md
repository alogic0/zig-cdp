# Plan: close the browser workflow gaps

Date: 2026-10-22

Status: implementation in progress; slices 1–4 delivered; integration checks pending

Baseline: zig-cdp 0.2.0 at `30b60ef`, compared with the standalone Node CDP
client at `71284ed` and its task-resolution workflow. This extends the completed
[agent usability plan](2026-10-21-agent-usability.md).

The goal is **to complete browser work through the native CLI while keeping an
existing visible Chrome window in the background**. An agent should be able to
create task tabs, inspect and operate controls, capture errors and API responses,
perform a drag, upload several files, and disconnect without writing a Zig,
Python, or Node controller for those operations.

This document records the delivery contract. Slices 1–4 are implemented; command
examples in later slices remain proposed until their checks pass.

## What already works

Existing-browser attachment, stable tab IDs, semantic locators, bounded page
inspection, keyboard input, screenshots, downloads, structured failures, and
whole-command deadlines are implemented. Preserve these capabilities and the
ownership rules in [DESIGN.md](../../DESIGN.md).

Use `--endpoint` for an existing user-controlled browser. Attachment adds no
origin allowlist, viewport override, or persistent download-directory change.
The previous localhost block came from an owned `serve` session's interception.
Attaching another client does not remove restrictions installed by that owner.
Do not solve this by silently weakening owned-session policy.

The comparison verified the `agent` and `endpoint` CLI groups in Debug and
ReleaseSafe, and all five Node tool tests, including its browser fixture.
Those checks used disposable headless browsers. They do not establish desktop
focus behavior; that gap was identified from the source and workflow contract.

## Gaps and delivery order

| Priority | Gap | Required result |
| --- | --- | --- |
| 1 | New tabs and some attachments activate Chrome | Create and operate background tabs without requesting desktop activation |
| 2 | CLI has no persistent console/network observation | Capture diagnostics before navigation and correlate responses with actions |
| 3 | Custom input sequences require a separate controller | Perform a held drag and bounded protocol sequences through the CLI |
| 4 | Upload accepts only one file | Set multiple files in one operation |
| 5 | The workflow still depends on Node-specific commands | Document and verify the native replacement before consumer adoption |

Implement and commit each slice with its documentation and meaningful regression
checks. Keep application routes, credentials, task-board rules, and deployment
policy in consumers. This plan does not introduce an MCP server, a JavaScript
host runtime, frame/shadow-root traversal, or a general-purpose scripting language.

## 1. Separate tab selection from activation

Add `new-tab [URL] --background` in both ownership modes. It must send
`Target.createTarget` with `background: true` and must not activate the target
while attaching, navigating, or reporting its result. In an owned session it
still selects the new tab for subsequent CLI commands; browser selection and
CLI selection are different state.

Add `switch-tab ID --background` for owned sessions to change only CLI selection.
Endpoint commands already require `--tab ID`, so they need no stored selection;
reject this option in endpoint mode with a clear explanation. Preserve the
existing foreground behavior of unqualified `new-tab` and `switch-tab` for
compatibility, and make the background form the documented agent workflow.

Inspect every implicit activation path, not just tab creation:

- [cli_endpoint.zig](../../src/cli_endpoint.zig): creation and explicit activation.
- [cli_session.zig](../../src/cli_session.zig): attachment through `--tab`,
  selection recovery, last-tab replacement, and navigation-failure cleanup.
- [cdp_journey.zig](../../src/cdp_journey.zig): `connectPage` currently calls
  `Page.bringToFront`, including when attaching to an existing page.

Give the library explicit creation/attachment options while preserving existing
public entry points. CLI inspection and ordinary actions must attach without
activation. Implicit recovery must not raise Chrome. Foreground requests remain
explicit operations; document any intentional compatibility change to recovery.
Never use desktop pointer movement, OS keyboard injection, or window-manager
activation to make page actions work.

**Acceptance:** add a separate focus regression under Xvfb with an owned window
manager and a second foreground fixture window. Observe the active native window
and selected Chrome tab before and after background creation, navigation,
attachment, fill/click, screenshot, and error recovery. Verify CLI selection,
preserved form values, and unchanged native viewport in both ownership modes.
Assert that background paths issue no activation commands. Keep the existing
viewport test: it intentionally activates documents and cannot prove this rule.

Use the user's actual desktop only for an authorized final visible check. Initial
window creation and browser dialogs can still activate Chrome; do not promise an
absolute focus guarantee across platforms or replace the visible workflow with
headless Chrome.

## 2. Observe console errors and network activity across commands

Add a finite foreground observer, for example:

```sh
zig-cdp --endpoint "$endpoint" observe --tab "$tab_id" \
  --events console,exceptions,network --duration 30000 --out "$capture"
```

An agent starts this with its persistent-process facility, waits for readiness,
then runs navigation and actions through separate CLI invocations. Use an
independent borrowed connection so observation cannot occupy the owned session's
serial command loop or block its actions. For `--session`, obtain the endpoint
and exact target through the owner, then observe separately without acquiring
browser ownership. Require an explicit tab in both modes.

Define the public contract before implementation:

- Enable the requested domains and install event handling before emitting the
  readiness record. No capture before that point is promised.
- Write versioned JSON Lines to a private capture file. Refuse an existing
  destination. Stdout contains readiness and a final summary; this is an explicit
  exception to the ordinary one-result command contract.
- Include target ID, observer sequence number, timestamps, navigation/frame
  identity when available, and request ID. Correlate request, response, loading
  completion, redirects, and failures without matching unrelated traffic.
- Console/exception records contain bounded text and source locations. Network
  records default to method, origin/path, status, type, timing, and failure.
  Omit headers, cookies, URL credentials/query/fragment, and request/response
  bodies by default. Console text can itself contain secrets; document this and
  avoid recursive object expansion.
- Support explicit response-body capture filtered by method and exact URL,
  enabled before the action. Fetch bodies after completion without replaying
  the request. Record unavailable, oversized, binary, and truncated bodies
  explicitly. This must allow checking a save action's actual API response.
- Bound duration, retained request metadata, event count, event size, output
  bytes, and each body. Start with a 120-second duration ceiling, 4,096 retained
  request/event records, an 8 MiB capture ceiling, and 1 MiB per body within that
  ceiling. Define overflow counters and a nonzero partial-capture result rather
  than silently claiming complete evidence. Keep defaults and limits in help.
- Expiry is normal completion. SIGINT/SIGTERM, tab closure, browser exit,
  connection failure, and output failure produce bounded finalization and an
  explicit completion reason. Release sockets and storage; never close Chrome
  or retry application actions.

Keep the observer in the CLI/agent layer. Do not globally enable the journey
library's arena-retained observations. Compose event handling without replacing
the owned origin-policy handler or breaking explicit download capture. Domain
cleanup must affect only the observer's connection. Do not add Fetch interception
or disable cache/service workers merely to observe traffic. Bound work on quiet
connections as well as busy ones, including on a single CPU.

**Acceptance:** start observation before navigating a local fixture, then use
separate commands to trigger a console message, exception, successful JSON POST,
HTTP rejection, redirect, and failed request. Prove request/body correlation,
readiness ordering, filtering, finite output, and diagnostics across reloads.
Exercise quiet expiry, overflow, interruption, output failure, and target/browser
closure. Preserve unrelated tabs, default network behavior, profile, and viewport.
Include an owned-session case with active interception and an explicit download.
Document that automatic observation of workers and separate frame targets is
outside this first slice.

## 3. Expose the input operations that currently need controllers

Add a native `drag` operation with strict source/destination locators, bounded
hold duration, and movement steps. Resolve live geometry instead of requiring
hard-coded screen coordinates. Reuse actionability checks and CDP mouse input.
Keep all input inside the page and preserve desktop focus.

For operations beyond the named commands, add a page-scoped `protocol` command
accepting a method and JSON parameters from a file or stdin. Expose the initial
supported method set explicitly; keep browser/context lifecycle operations in
the typed ownership-aware commands. Arbitrary browser-level protocol access is
not needed for this slice and must not invalidate endpoint disconnect guarantees.
Validate method scope, target, and JSON before dispatch, and retain existing
response bounds and action-progress diagnostics.

Add a versioned JSON `sequence --file PATH|-` format for a bounded list of
existing page commands, supported protocol calls, and timed pauses on one tab.
Keep one connection for the sequence so press/hold/move/release operations share
input state. Validate the full input before starting, use one overall deadline,
stop at the first failure, and report each step's index and dispatch status.
Do not add branching, loops, executable host code, or automatic replay. Native
`drag` handles the geometry needed by the demonstrated workflow; a general
result-binding language can remain deferred.

If a drag or sequence fails after mouse-down, attempt a bounded mouse-up on the
same live target without suppressing the original failure. Track held keys as
well. Report incomplete release when the target/connection is lost, and require
inspection before retrying a write.

**Acceptance:** move a local sortable card whose sensor requires a held press
and incremental movement. Verify final position and trusted pointer events.
Cover ambiguous, disabled, covered, and moving controls; navigation/tab closure
and cancellation during a held input; malformed sequence input; step failure;
and total-budget expiry. Check that the next action is usable after recoverable
failure. Run in both ownership modes without Node/Python helper programs.

## 4. Support multiple-file uploads

Extend upload with repeated `--file PATH`, retaining positional single-file
syntax. Resolve every path relative to the invoking client, validate the full
list before changing the input, and send one `DOM.setFileInputFiles` operation.
Require a file input; reject multiple paths unless it has `multiple`. Retain
hidden-input support and disabled-input rejection. Bound file count and total
request size; document replacement of the existing selection.

**Acceptance:** a local multiple-file form receives the exact two file contents
in order, with filenames containing spaces and Unicode. Invalid paths, too many
files, ambiguous locators, and a single-file control fail before partial updates.
Verify positional compatibility and execution from another working directory in
both ownership modes.

## 5. Verify the replacement workflow and document adoption

Extend the native acceptance runner and shared fixtures instead of introducing
another test framework. Keep all fixtures, profiles, ports, process handles,
and cleanup under test ownership. Reuse the existing timeout, resource, and
single-CPU regressions; add observer/sequence workloads without weakening their
current thresholds. State separately what CLI memory bounds and Chrome memory
measurements establish.

Use a complete local scenario: create a background tab, start observation, wait
for readiness, navigate, inspect controls, fill/save, verify the matching response
and rendered result, drag a card, upload two files, download an artifact, reload,
capture a screenshot, finish observation, and disconnect. Preserve a sentinel
tab's unsaved form, native viewport, foreground window, and external browser.
Run an equivalent owned-session scenario with its origins explicitly configured.

Required implementation checks, using the compiler pinned in `.zigversion`:

```sh
zig fmt --check src tests examples build.zig
zig build test-cli test check example --summary all
zig build test-cli test check example -Doptimize=ReleaseSafe --summary all
zig build test-headed -Dheaded-window-manager=true --summary all
zig build test-headed -Dheaded-window-manager=true -Doptimize=ReleaseSafe --summary all
git diff --check
```

Run focused groups for each slice, then the combined checks at integration.
Preserve the single-CPU CLI CI lane in both profiles. When public library APIs
change, run the independent exported package consumer in both profiles using
the existing package-verification procedure. Review staged changes and commit
each verified slice with a temporary message file via `git commit -F`.

Update [README.md](../../README.md), [docs/cli.md](../cli.md),
[docs/library.md](../library.md), [DESIGN.md](../../DESIGN.md), and
[CURRENT_STATUS.md](../../CURRENT_STATUS.md) with the relevant slice. Include
copyable endpoint examples, foreground/background semantics, observer readiness
and lifetime, capture schema/limits, sequence errors, and upload compatibility.
Keep proposed features distinct from delivered features until checks pass.

Consumer adoption is a separate update after these checks pass: replace Node
commands with their Zig equivalents, keep the exact existing browser/profile,
discover its live endpoint rather than assuming a remembered port, and require
explicit tab IDs. Keep the visible window open for inspection. Adapt any
historical Playwright controllers separately; they are not compatible with
either CLI merely because both use CDP. This plan does not modify the external
workflow or switch its default tool.

## Completion criteria

- Background creation, attachment, ordinary actions, and recovery meet the focus
  contract with evidence from a headed fixture.
- An agent captures console/network evidence before an action and verifies the
  matching response using separate native CLI invocations.
- Held drag, supported protocol sequences, and multiple-file upload require no
  auxiliary controller program.
- Both browser ownership modes retain their cleanup, deadline, origin, and
  resource guarantees; external Chrome survives disconnection and errors.
- Debug, ReleaseSafe, headed, single-CPU, and affected package checks pass, and
  documented commands reproduce the complete local workflow.

## References

- [Current CLI contract](../cli.md)
- [Native acceptance requirements](2026-10-21-native-cli-test-requirements.md)
- [CDP target creation and activation](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Target.pdl)

The Node comparison checkout identified above is a local reference, not a
package dependency.
The implementation and public usage documentation must remain self-contained.

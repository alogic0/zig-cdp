# Requirements: rewrite CLI acceptance tests in Zig

Date: 2026-10-21

Status: proposed

Replace [tests/cli.py](../../tests/cli.py) with a native Zig runner while
preserving its coverage. After migration, building, using and testing zig-cdp
must require no Python interpreter.

Shared infrastructure extraction is a separate cross-repository project.
This task should adopt verified independent libraries once they are available;
it does not own extracting components from application repositories.

1. **Run the real CLI.**

   Add a runner such as `tests/cli.zig`, compiled with the version pinned in
   `.zigversion`. Receive the built CLI artifact's path from the build system.
   Continue invoking commands as separate processes so argument parsing,
   stdin/stdout, exit codes and session transport remain under test. Calling
   library functions directly must not replace CLI acceptance checks.

2. **Provide bounded process helpers.**

   Reuse pinned `zig-process` and verified shared test-support helpers. Support
   arguments, working directories, optional stdin, separate stdout/stderr capture,
   exit-status checks and deadlines. Drain output without pipe deadlocks. Report
   capture overflow explicitly. Allow asynchronous commands for interruption
   tests. On timeout or assertion failure, stop and join owned processes before
   releasing their resources.

3. **Manage persistent test sessions.**

   Start `serve` in the foreground and wait for its readiness JSON with a finite
   deadline. Keep its process handle and stderr available for diagnostics.
   Run multiple independent sessions concurrently. Verify that close, idle
   expiry and signals remove the owned socket, session directory and temporary
   profile, while preserving a supplied profile and unrelated processes.

4. **Manage an external Chrome fixture separately.**

   Launch Chrome with a fresh test-owned profile and an ephemeral loopback
   debugging port. Read its DevTools endpoint and configure fixture downloads
   inside the test workspace. Preserve the distinction between the runner owning
   this Chrome process and endpoint commands borrowing it. Verify that command
   completion, failures and interruption preserve Chrome, its profile, native
   viewport and unrelated tabs. Stop Chrome only during fixture teardown.

5. **Provide concurrent network fixtures.**

   Adopt the independent HTTP fixture library on an ephemeral loopback port.
   Serve pages, background requests, normal downloads and slow streaming downloads. Observe
   request arrival and transfer cancellation. Support malformed discovery JSON,
   HTTP errors, invalid WebSocket upgrades and stalled responses.

   Service requests while CLI processes are running, including overlapping
   requests. Use bounded I/O, explicit synchronization and deadlines. Shutdown
   must cancel or finish handlers, close sockets and join fixture tasks.

6. **Provide protocol, file and assertion helpers.**

   Support raw Unix-socket requests, including invalid JSON, wrong field types
   and oversized messages. Provide independent HTTP requests for Chrome target
   inspection and fixture control where the current tests use them.

   Create private temporary workspaces and remove only test-owned files. Check
   file bytes, permissions, symlinks and profile markers. Parse JSON replies and
   PNG header dimensions. Read Linux `/proc` data for process presence, owner RSS
   and descriptor counts. Assertion failures must identify the scenario, command,
   expected result and actual result, with bounded diagnostic output.

7. **Preserve every existing scenario.**

   Map each Python scenario to its Zig replacement before removing it. Retain
   the following coverage:

   | Area | Required checks |
   | --- | --- |
   | CLI contract | Help, argument validation, JSON envelopes, errors, exit codes, stdin, files and client-relative paths |
   | Session transport | Shared state across processes, malformed/oversized requests, response limits, collisions and independent sessions |
   | Browser actions | Navigation/reload, content, evaluation, strict semantic/CSS/text locators, trusted input, select, keyboard, waits and actionability failures |
   | Inspection and artifacts | Bounded Unicode text and accessibility snapshots, truncation, uploads, exact downloads, private output files and screenshot dimensions |
   | Tabs and profiles | Selection, explicit target IDs, shared cookies/storage, background tabs, externally closed tabs, last-tab replacement, saved profiles and stale/busy endpoints |
   | External attachment | HTTP/WebSocket endpoints, explicit target requirements, native viewport, absence of persistent helpers, HTTP/blob downloads and ownership preservation |
   | Faults and cleanup | Launch failures, browser exit during work, discovery faults, command deadlines, SIGINT/SIGTERM, idle expiry and streaming download cancellation |
   | Resource bounds | Repeated inspection and tab cycles, owner RSS/descriptors, origin limits, denied automatic downloads and staging cleanup |

   Preserve the current resource workload: warmup, 720 inspection/evaluation
   commands and 36 tab cycles. Retain the RSS-growth threshold below 32 MiB and
   descriptor allowance of at most three above baseline unless measurements
   justify a documented change. Do not weaken assertions to make the port pass.

8. **Keep ownership and dependency boundaries.**

   Keep the runner and CLI-specific fixtures in test code. Pin shared fixture
   and test-support libraries as test dependencies. Add no new production
   runtime dependency or test framework. Use unique directories and dynamic
   ports; never use a personal browser profile or attach to an unrelated browser.
   Signal and process-group operations must target test-owned processes only.
   The rewrite must not add signal handlers, unrelated-child reaping or test
   policy to the public library. No public CDP API change is required.

9. **Preserve the build interface and update CI.**

   Keep `zig build test-cli`. Replace the Python system command in `build.zig`
   with a compiled Zig runner and pass the CLI artifact to it. Compile both
   artifacts in the selected Debug or ReleaseSafe profile. Return nonzero on
   test failure and ensure acceptance tests execute rather than reuse a cached
   successful run against external state.

   Keep the existing library, example, package-consumer and headed Xvfb checks.
   Remove the explicit Python check from CI and update README/CLI documentation
   when the replacement is complete. Chrome and Xvfb requirements remain.

10. **Demonstrate parity before removing Python.**

    Port process/session helpers first, then network fixtures and scenario
    groups. Keep the Python runner available during migration. Run both suites
    against the same CLI build, using separate workspaces, in Debug and
    ReleaseSafe. Resolve differences before switching `test-cli` and deleting
    the Python runner.

    Acceptance requires the complete native suite to pass in both profiles,
    including failure-path cleanup and resource checks. Run existing library,
    example, package and headed regressions; format Zig sources; check
    documentation links; and run `git diff --check`. Confirm the final
    `test-cli` build path invokes no Python. Record results in
    [CURRENT_STATUS.md](../../CURRENT_STATUS.md).

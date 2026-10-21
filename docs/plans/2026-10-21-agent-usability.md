# Plan: improve zig-cdp for agent use

Date: 2026-10-21

Status: implemented (2026-10-21)

Delivery: inspection and interactions in `4ab0c81`; external attachment in
`6e90c40`; resource bounds, deadline/error completion and final workflow
verification complete the delivery in version 0.2.0. See
[CURRENT_STATUS.md](../../CURRENT_STATUS.md) for finite verification evidence.
Frame/shadow-root support, batching and MCP remain deferred as planned.

The goal should be: **an agent can inspect a page, identify a control, act, and
verify the result using short commands, with clear browser ownership.**

Much of the action machinery already exists in the library. The main gaps are
CLI coverage, accessibility inspection, and attachment to an existing browser.

1. **Add page inspection and semantic locators — highest priority.**

   Add bounded `read` and `snapshot` commands. Snapshots should expose Chrome's
   accessibility roles, names, relevant states, and node identifiers, with
   explicit truncation metadata.

   Support a shared locator syntax across commands: `--selector`,
   `--role … --name …`, and `--text`. Preserve existing positional CSS commands.
   Use Chrome's accessibility data for role/name matching; the current JavaScript
   helper approximates accessible names and roles.

   **Acceptance:** an agent can discover and click a fixture's controls without
   writing inspection JavaScript. Missing and ambiguous matches produce distinct
   errors.

2. **Complete common interaction commands.**

   Expose `select`, general keyboard `press`, and locator waits for `visible`,
   `hidden`, `attached`, and `detached`. Reuse existing library functionality
   where available. Add explicit viewport/full-page screenshot options and verify
   their actual image dimensions.

   Add `--value-file PATH|-` for input and `eval --script PATH|-` for longer
   expressions, while retaining inline evaluation.

   **Acceptance:** fixtures cover keyboard shortcuts, select controls, trusted
   text input, hidden upload controls, covered/disabled elements, and pages taller
   than the viewport.

3. **Support existing-browser attachment.**

   Add direct endpoint commands such as:

   ```sh
   zig-cdp --endpoint http://127.0.0.1:9239 tabs
   zig-cdp --endpoint http://127.0.0.1:9239 snapshot --tab TAB_ID
   zig-cdp --endpoint http://127.0.0.1:9239 click --tab TAB_ID --role button --name Save
   ```

   Introduce a connection type that borrows a browser, alongside the existing
   owned `Browser`. Basic attached commands should finish without requiring a
   persistent `serve` process.

   Attachment must avoid the current launch setup's automatic viewport,
   download-directory, and request-interception changes. Disconnecting must
   preserve the browser, its profile, and unrelated tabs. Require explicit tab
   IDs for attached page operations.

   **Acceptance:** closing or interrupting the tool leaves the externally started
   browser usable. Existing owned-session cleanup tests continue passing.

4. **Make results and failures easier for agents to use.**

   Keep the existing JSON envelope and add consistent structured details:
   command, target, error code, locator match count, and truncation information.
   Distinguish missing elements, ambiguous matches, covered controls, timeouts,
   and disconnected targets.

   Support per-command timeout overrides. After a failure during an action,
   report whether input was already dispatched when known; an agent should be
   able to inspect the result before deciding to repeat it.

   **Acceptance:** an agent can choose its next step from JSON without parsing
   owner-process stderr.

5. **Bound resource use during longer sessions.**

   Introduce request-scoped allocation for temporary inspection and command
   results. Retain only necessary session state, and bound captured events,
   responses, downloads, and detached-page records.

   Apply command deadlines through nested CDP operations and handle browser exit
   or navigation without leaving blocked requests.

   **Acceptance:** repeated inspection and tab cycles keep memory and descriptor
   use bounded; cancellation preserves the ownership rules in both browser modes.

6. **Verify complete agent workflows and document them.**

   Extend the existing fixtures rather than creating a parallel test framework.
   Cover the same practical workflow in owned and attached modes: discover
   controls, fill, select, press, navigate, upload/download, capture a screenshot,
   verify, and finish.

   Run meaningful regressions in Debug and ReleaseSafe, including headed Xvfb
   checks and package checks when public APIs change. Update the agent guide
   alongside each feature.

Implement **inspection and interaction coverage first**, then existing-browser
attachment. Those deliver the largest immediate improvement. Frame/shadow-root
support, command batching, and MCP integration can follow demonstrated needs.

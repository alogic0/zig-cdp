# Plan: frames, shadow roots, workers and bounded shutdown

Date: 2026-10-22

Status: completed in 0.4.0

Baseline: zig-cdp 0.3.0, `30939e3`. This closes the deferred coverage described
in the browser-workflow parity plan and investigates its intermittent shutdown
timeout. Keep the repository independent, consumer policy outside the library,
and all tests on disposable profiles and private displays.

## 1. Make shutdown bounded under an unresponsive browser

Audit cancellation, page detach, Browser.close, exact-child wait and process-group
fallback. Add deterministic failure coverage using a suspended owned browser,
plus repeated single-CPU lifecycle checks. Preserve the ten-second CLI shutdown
gate and caller-owned profiles/unrelated processes. Fix evidenced defects; do
not claim an intermittent symptom's exact cause without reproducing it. Keep
signals and subreaper policy in the CLI, and record remaining uncertainty.

## 2. Add document and target routing

Extend the serialized transport with flattened CDP session routing. Add a
bounded, request-owned view of related iframe targets and default execution
contexts. Preserve the existing page socket's event/policy handler, use one
overall operation deadline, and detach only sessions created by this view.
Discovery must never activate windows or attach arbitrary unrelated pages.

Expose `frames` and `--frame ID` in owned and endpoint modes. Include parent ID,
URL and name in discovery. Apply frame selection consistently to evaluation,
locators, snapshots, fill/click/press/select/wait/upload, drag and sequences.
Route same-process and out-of-process frames, including nested cross-origin
frames. Resolve contexts after navigation; detached/stale frames must fail
explicitly without falling back to another document or replaying a write.
Translate pointer coordinates through frame owners and check ancestor clipping
and occlusion. Reject geometry that cannot be mapped safely before dispatch.
Keep browser/tab lifecycle and full-page screenshots scoped to the top-level
tab; document command scope rather than silently ignoring frame selection.
Retain owned origin policy across frame attachment and navigation.

## 3. Add explicit shadow-root traversal

Expose repeated `--shadow HOST_CSS` for a strict host chain within the selected
document. Support open and closed author shadow roots through CDP DOM handles,
without modifying attachShadow or application code. Add `shadow-roots`
inspection with host selectors/paths and root types. Bound traversal depth,
nodes and output; exclude browser-internal user-agent roots.

CSS, text and role/name lookup, read/snapshot, input, upload, wait and drag must
honor the selected root. Traverse composed ancestors for disabled/inert state
and hit testing. Cover nested roots, slots, duplicate labels across components,
covered/moving controls, detached/replaced hosts, and frame-plus-shadow usage.
Keep default document-only CSS behavior compatible and make root selection
explicit in help, examples and sequence validation.

## 4. Observe related and explicitly selected workers

Extend finite observation with opt-in related-target coverage and explicit
worker IDs for shared/service workers whose association is ambiguous. Discover
worker IDs without selecting them by URL or origin alone. Recursively observe
related dedicated workers and iframe targets; enable Runtime/Network on each
selected target. Handle startup, nested creation, termination and reattachment.
If new targets are briefly paused to install observation, always resume them,
including failure and cancellation cleanup.

Every record must identify its actual source target/type/session. Scope request
and body correlation by session as well as request ID. Keep exact method/URL
body filters and explicit unavailable/oversized/partial outcomes. Share global
duration, event and byte budgets, bound target/context maps, and reclaim detached
target state. Preserve unrelated workers, browser ownership, network/download
policy, profile and focus. Readiness covers configured initial targets; report
later target readiness and loss rather than promising pre-attachment history.

## 5. Verify and document adoption

Extend the existing native fixtures with same-origin, cross-origin/site-isolated
and nested frames; nested open/closed shadow components; dedicated/nested/shared/
service workers with console, exception and correlated response evidence. Use
both CLI ownership modes and test failures, navigation, cancellation, cleanup,
limits and unchanged unrelated targets. Add a combined frame/shadow workflow to
the headed focus fixture and extend the finite resource workload without raising
its RSS/descriptor thresholds.

Run focused Debug and ReleaseSafe checks for each slice, the full single-CPU CLI
suite, library/example checks, Xvfb/Openbox focus/viewport gates, and independent
exported-package consumers when public APIs change. Use the pinned compiler.
Format Zig, check documentation links and `git diff --check`, review staged
changes, and commit each verified slice using a temporary commit-message file.
Remove temporary verification files. Update README, CLI/library guides, DESIGN,
CURRENT_STATUS and this plan with measured results and precise remaining bounds.

## Completion criteria

- An agent discovers/selects a nested cross-origin frame and author shadow root,
  performs normal CLI actions and verifies results without a helper controller.
- Worker evidence identifies its target, survives relevant lifecycle changes,
  correlates bodies correctly and preserves unrelated browser state.
- Shutdown fault regressions pass within existing budgets; any unresolved
  historical diagnosis is clearly distinguished from verified fixes.
- Both build profiles, single-CPU, package and headed gates pass with unchanged
  resource thresholds and documented commands.

## Delivery and verification

All five sections are delivered. Shutdown cancellation, explicit frame routing,
open/closed author-root scoping and worker observation are implemented and
documented in the CLI/library guides. The integration slice adds frame-owner
inert checks, strict focus checks, held-frame cancellation/navigation coverage,
linear wide-DOM discovery and source-session validation. TCP_NODELAY removes
the observed roughly 40 ms waits at WebSocket writer-buffer boundaries; the
existing 350 ms held-input timeout regression passes without a larger budget.

Final checks used Zig 0.17.0 and Chrome 155.0.8059.84:

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| Full native CLI on one allowed CPU | 14 groups passed | 14 groups passed |
| Library/observer tests on one CPU | 14/14 passed | 14/14 passed |
| Compile, example, install | passed | passed |
| Private Xvfb/Openbox focus and viewport | passed | passed |
| Independent exported consumer | 1/1 passed | 1/1 passed |

The combined command was `zig build test-cli test check example install --summary all`,
run under `taskset -c` with one allowed CPU, then repeated with
`-Doptimize=ReleaseSafe`. Headed gates use `zig build test-focus test-headed` in
both profiles. The exported consumer uses a repository copy without `.git` or
repository caches and a separate global cache, initially populated from empty.
It exercises frame routing, closed roots, named input and worker discovery.

The full native runs and corresponding headed fixtures reported these CLI hashes:

- Debug: `345b647739b84a6573dd17a1149d238809a3f6707e0df0dc8e252f7fdd89bffd`.
- ReleaseSafe: `1e73637b231db79934203f47ee2c40d7b7bdf7efa15c6972b00402a6655d1636`.

The installed executable reports `zig-cdp 0.4.0` and matches the ReleaseSafe hash.
The resource workload includes the original 720 inspections / 36 tab cycles /
12 sequences, plus 12 frame/closed-shadow cycles and worker observation. Debug
owner RSS was 10,674,176 → 11,644,928 bytes; ReleaseSafe was
4,190,208 → 4,907,008. Descriptors stayed 7 → 7. The limits remain 32 MiB RSS
growth and at most three extra descriptors.

Shutdown retains its ten-second gate and eight fault cases; the separate injected
cancellation regression verifies the propagation fix. The original intermittent
timing remains unreplicated. Related worker replacement is handled through new
target/session IDs; explicitly selected shared/service replacements require
rediscovery. Unsupported frame transforms fail before dispatch, and traversal,
context, target, request and output caps remain explicit in the guides.

Local documentation links, Zig formatting and `git diff --check` pass. Temporary
verification exports/caches and locally extracted Openbox packages were removed.
Tests use disposable profiles and private displays. Repository changes are
reviewed and committed in valid slices using temporary commit-message files.

## Protocol references

- [Target protocol](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Target.pdl)
- [Page protocol](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)
- [DOM protocol](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/DOM.pdl)
- [Runtime protocol](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Runtime.pdl)

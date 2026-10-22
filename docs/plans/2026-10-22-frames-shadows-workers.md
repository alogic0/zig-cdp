# Plan: frames, shadow roots, workers and bounded shutdown

Date: 2026-10-22

Status: implementation in progress; shutdown slice verified

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

## Protocol references

- [Target protocol](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Target.pdl)
- [Page protocol](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)
- [DOM protocol](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/DOM.pdl)
- [Runtime protocol](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Runtime.pdl)

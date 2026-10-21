# Native CLI acceptance migration

The [requirements](2026-10-21-native-cli-test-requirements.md) authorize the complete
port of `tests/cli.py`, preserving subprocess acceptance and existing thresholds.
Starting source: `4f50732127c333cf36f95ad98b5289c50c5f3a7c`, Zig 0.17.0.
The requirements file existed untracked before this task; its original proposal
is preserved in foundation commit `bd5d3d3`.
No public CDP API or production behavior change is selected.

## Finite scenario map

Original Python line ranges refer to the starting revision. Each native group
retains its assertions; Python was kept available until both implementations
passed against the same CLI artifacts in Debug and ReleaseSafe.

| Group | Original coverage | Native destination | Status |
| --- | --- | --- | --- |
| Process/session foundation | `command`, `Session`, `raw_request`, main 549–566 and close/isolation 632–637 | `cli_support.zig`, `cli_contract.zig` | Passed Debug/ReleaseSafe |
| Contract/actions/files | main 549–637: validation, framing, trusted input, exact bytes, client cwd, errors/recovery, background requests | `cli_contract.zig` | Passed Debug/ReleaseSafe |
| Tabs | `exercise_tabs`, 145–229: identities, selection, persistent/default contexts, origins, external create/close, last-tab replacement | `cli_tabs.zig` | Passed Debug/ReleaseSafe |
| Agent actions | `exercise_agent_commands`, 267–364: semantics, actionability, Unicode, stdin/files, structured errors, uploads/downloads, screenshots | `cli_agent.zig` | Passed Debug/ReleaseSafe |
| External ownership | `ExternalBrowser`, `exercise_endpoint`, 75–123 and 367–423: HTTP/WS endpoints, borrowing, geometry, tabs, downloads, signals | `cli_endpoint.zig` | Passed Debug/ReleaseSafe |
| Resources and transfer cancellation | `exercise_resources`, 426–503: warmup, 720 commands/36 tab cycles, RSS <32 MiB, descriptors <=baseline+3, staging/origins/browser death | `cli_resources.zig` | Passed Debug/ReleaseSafe |
| Discovery | `exercise_discovery_failures`, 506–545: status/JSON/upgrade/stalled discovery and exact errors/bounds | `cli_faults.zig` | Passed Debug/ReleaseSafe |
| Shutdown/profiles | main 647–732: signals during work, idle expiry, collisions, failed launch, saved profiles/cookies/storage, stale records and symlinks | `cli_lifecycle.zig` | Passed Debug/ReleaseSafe |

## Provider and ownership boundaries

Test-only imports pin HTTP 0.2.1 `b51873725fecd7936078e64026b6ea664783773e`
and support 0.1.0 `e23cb642765677807c2e80f613fb873f9780554a` by local immutable
archives and Zig package hashes. Archives are included in the package export;
no sibling checkout is needed. Both consume the existing process 0.5.1 identity.
Only the native runner imports these new modules; production `cdp` is unchanged.

`Context` owns parsed snapshots in a scenario arena. Process reports release
immediately after copying parsed strings. Resource workloads use shorter request
arenas. Session owners retain their exact child and readiness/stdout ownership;
stderr goes to a private test log for bounded failure excerpts. Teardown sends
TERM and joins before releasing storage. No test signal handlers or unrelated
child reaping are installed. Required browser absence is a failure, never a skip.

HTTP route data, Unix protocol assertions, saved-profile markers and browser
ownership remain local to the tests. General accept loops, response pacing,
workspaces, capture, readiness and resource measurements use the providers.

## Verification

Raw logs and reference bytes are retained outside caches at
`cdp-native-cli-evidence-o8B0ll`.
The original Python suites pass both profiles against separately retained CLI
binaries. RSS: Debug 8256→8724 KiB, Safe 3032→3388 KiB; descriptors 7→7.
The complete native suite passes all six groups in Debug and ReleaseSafe (four
build steps each), including the tabs subcases in temporary and saved profiles.
Both suites used byte-identical CLI artifacts in each profile:

| Profile | CLI SHA-256 | Native owner RSS bytes | Descriptors |
| --- | --- | --- | --- |
| Debug | `199347483cb963b98197a11026437b77511099d7cd3125ccfaf2deae84b8b1c2` | 8,515,584 → 8,605,696 | 7 → 7 |
| ReleaseSafe | `b951f3d2f8d23f0d0423581f97f04e655ec6bd6c3b63c8ebb0b7257e61508213` | 3,084,288 → 3,448,832 | 7 → 7 |

The workload remains 24 warmup commands, 720 inspection/evaluation commands and
36 tab cycles. Both interrupted streams reached the fixture, failed their writes
within two seconds after CLI failure, and joined before teardown. No threshold
was relaxed. PNG checks additionally validate headers/dimensions; fill output
checks reject the unescaped secret prefix as well as preserving exact stdin.

Logs: `python-debug.log`, `python-safe.log`, `native-full-debug.log`, and
`native-full-safe.log`. Initial port/compiler failures remain in the evidence
folder; the HTTP PUT helper now sends the empty body required by std.http.
The initial panic's two owned sessions were explicitly stopped and their private
workspace removed. Later failure paths unwind their owned sessions normally.

## Final build switch and regression gates

`test-cli` now compiles and runs the native runner, passes the built CLI artifact,
and forwards optional `--case NAME` arguments. Unknown groups fail instead of
silently succeeding. Runner, fixture and support modules use the selected mode;
`has_side_effects` forces execution against real browser state. The incremental
`test-cli-native` name and Python runner are removed. CI retains its existing
Debug/ReleaseSafe matrix, library, example, package and headed steps and drops
the interpreter check. README and CLI guidance describe the native commands.

The combined `test-cli test check example install test-headed` command passes
16/16 steps in each profile (`final-debug.log`, `final-safe.log`). The final full
native runs also pass all six groups with compilation cached, proving execution
is not skipped (`final-native-debug.log`, `final-native-safe.log`). Their resource
measurements are Debug 8,511,488→8,605,696 bytes and Safe 3,100,672→3,497,984 bytes,
with seven descriptors throughout. This bounds the session owner over the finite
workload, not Chrome memory or indefinite operation.

An exported source tree with no sibling provider checkouts and an initially empty
private global cache passes the independent package consumer 1/1 and library
10/10 in both modes (`package-debug2.log`, `package-safe.log`, `library-debug.log`,
`library-safe.log`). The export includes vendor archives and fixture HTML and
excludes Git metadata, caches and generated dependencies. The tested source
archive is retained as `tested-package-source.tar.gz`; temporary source/cache
directories were removed after checks. Library warnings are expected negative
fixture diagnostics; all ten tests pass.

Final diagnostic refinements copy the last operation into a bounded buffer,
independent of request arenas, and report capture outcome, exit/cleanup state
and bounded stdout/stderr. Fixture observations and raw requests retain finite
deadlines. Follow-up discovery checks exercise the error envelopes in both modes.
Formatting, relative Markdown link targets, and `git diff --check` pass. An audit
of active build, test and CI sources finds no Python invocation; production
source files are byte-for-byte unchanged from the starting revision.

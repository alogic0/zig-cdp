# Native CLI acceptance migration

The [requirements](2026-10-21-native-cli-test-requirements.md) authorize the complete
port of `tests/cli.py`, preserving subprocess acceptance and existing thresholds.
Starting source: `4f50732127c333cf36f95ad98b5289c50c5f3a7c`, Zig 0.17.0.
The requirements file existed untracked before this task; its text is preserved.
No public CDP API or production behavior change is selected.

## Finite scenario map

Original Python line ranges refer to the starting revision. Each native group
retains its assertions; Python remains available until both implementations pass
against the same CLI artifacts in Debug and ReleaseSafe.

| Group | Original coverage | Native destination | Status |
| --- | --- | --- | --- |
| Process/session foundation | `command`, `Session`, `raw_request`, main 549–566 and close/isolation 632–637 | `cli_support.zig`, `cli.zig:foundation` | Passed Debug/ReleaseSafe |
| Contract/actions/files | main 549–637: validation, framing, trusted input, exact bytes, client cwd, errors/recovery, background requests | `cli_contract.zig` | Pending |
| Tabs | `exercise_tabs`, 145–229: identities, selection, persistent/default contexts, origins, external create/close, last-tab replacement | `cli_tabs.zig` | Pending |
| Agent actions | `exercise_agent_commands`, 267–364: semantics, actionability, Unicode, stdin/files, structured errors, uploads/downloads, screenshots | `cli_agent.zig` | Pending |
| External ownership | `ExternalBrowser`, `exercise_endpoint`, 75–123 and 367–423: HTTP/WS endpoints, borrowing, geometry, tabs, downloads, signals | `cli_endpoint.zig` | Pending |
| Resources and transfer cancellation | `exercise_resources`, 426–503: warmup, 720 commands/36 tab cycles, RSS <32 MiB, descriptors <=baseline+3, staging/origins/browser death | `cli_resources.zig` | Pending |
| Discovery | `exercise_discovery_failures`, 506–545: status/JSON/upgrade/stalled discovery and exact errors/bounds | `cli_faults.zig` | Pending |
| Shutdown/profiles | main 647–732: signals during work, idle expiry, collisions, failed launch, saved profiles/cookies/storage, stale records and symlinks | `cli_lifecycle.zig` | Pending |

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
The initial native foundation passes Debug and ReleaseSafe (four build steps
each). Next are the remaining mapped groups and full parity. `test-cli` still uses Python;
`test-cli-native` is the incremental native path. Both artifacts use the selected
native mode, and native execution is explicitly uncached.

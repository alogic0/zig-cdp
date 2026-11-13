# CLI Usability & Verification Improvements (2026-11-13)

Status: implemented

This plan covers four focused improvements discovered during day-to-day browser
verification workflows, keeping `zig-cdp`'s strict safety, memory bounds, and
focus-preservation guarantees intact.

## 1. Bounded `exceptionDetails` on `BrowserEvaluationFailed`

### Current vs Expected

Evaluating JavaScript with a syntax error or uncaught exception currently returns:

```json
{
  "ok": false,
  "err": "BrowserEvaluationFailed",
  "command": "eval",
  "tab": "...",
  "frame": null,
  "error": {
    "code": "BrowserEvaluationFailed",
    "phase": "action",
    "match_count": null,
    "action": "possibly_dispatched",
    "step": null,
    "steps": [],
    "input_release": "not_needed"
  }
}
```

No line number, column number, or bounded error summary from CDP
`Runtime.evaluate` / `Runtime.awaitPromise` `exceptionDetails` is surfaced,
forcing callers to wrap scripts in manual `try/catch` harnesses or extra round
trips.

### Requirements

- When `Runtime.evaluate` or awaited promise rejection returns `exceptionDetails`
  on `eval` (or an `eval` step inside `sequence`), include a bounded, structured
  diagnostic summary on `error` (for example `detail` or `exception` with
  optional 1-based/0-based `line`, `column`, and a UTF-8-safe truncated summary
  capped at e.g. 512 bytes from `exceptionDetails.exception.description` or
  `exceptionDetails.text`, stripping control characters if needed and reporting
  `truncated: true` when clipped).
- Preserve existing `ok: false`, `err: "BrowserEvaluationFailed"`, and `error`
  fields for backward compatibility.
- Reclaim all diagnostic buffers per command within existing transport bounds.

## 2. Scoped Auto-Clearing Responsive Viewport Check

### Current vs Expected

Attached `--endpoint` operations deliberately avoid persistent device-metric
changes on the user's shared browser window, which previously left narrow/mobile
viewport layout checks blocked in attached workflows.

### Requirements

- Support an explicit, temporary viewport emulation mode that **guarantees**
  restoration (`Emulation.clearDeviceMetricsOverride`) before the command
  returns, errors, or cancels — following the exact same cleanup discipline used
  for held mouse/key input in `sequence`:
  - Either `--emulate-viewport WIDTHxHEIGHT` (e.g. `390x844`, validated positive
    bounded dimensions such as `160..7680` × `160..4320`, `deviceScaleFactor: 1`,
    `mobile: false` unless specified) on `screenshot` and/or `sequence`, OR a
    typed temporary viewport step/option on `sequence` + `screenshot` that
    applies `Emulation.setDeviceMetricsOverride` on the target page connection
    and unconditionally calls `Emulation.clearDeviceMetricsOverride` in the
    `defer`/cleanup path (reporting cleanup status if connection loss prevents
    clearing).
- Must never call `Page.bringToFront` or resize the OS/browser window.
- Document the exact option, bounds, and cleanup contract in `docs/cli.md` and
  `--help`.

## 3. Repeatable `--body-method` / `--body-url` Pairs in `observe`

### Current vs Expected

`observe` currently accepts only a single `--body-method METHOD --body-url EXACT_URL`
pair, requiring multiple separate observation passes when a single user flow
triggers 2–4 API endpoints sequentially.

### Requirements

- Allow repeating `--body-method METHOD --body-url EXACT_URL` pairs (up to a
  strict small ceiling such as 8 pairs) in a single `observe` invocation.
- Validate that `--body-method` and `--body-url` counts match and that each
  method is uppercase and each URL is an exact `http://` or `https://` URL before
  starting capture.
- Preserve single-pair CLI compatibility (`--body-method POST --body-url URL`
  continues to work unchanged) and existing `--body-limit` / `--max-bytes` /
  `unavailable_bodies` accounting.

## 4. Subcommand `--help` Without Session / Endpoint Validation

### Current vs Expected

Running `zig-cdp protocol --help` or `zig-cdp observe -h` without `--session` or
`--endpoint` currently exits `1` with `ExpectedSessionOption`.

### Requirements

- Recognize `-h` / `--help` anywhere in arguments (or after a subcommand name)
  before requiring `--session` or `--endpoint`, printing concise command/global
  usage to stdout and exiting `0`.

## Acceptance & Qualification

- Read `AGENTS.md`, `DESIGN.md`, and `CURRENT_STATUS.md` before editing.
- Use `/home/oleg/bin/zig` (`0.17.0` per `.zigversion`).
- Implement in clean, focused slices; commit each verified slice via
  `git commit -F <tempfile>` and remove the tempfile with plain `rm <tempfile>`.
- Format Zig sources (`zig fmt --check`), run `git diff --check`, and run unit
  and CLI subprocess tests in both Debug and `ReleaseSafe` using private build
  caches/prefixes during iteration so an active `zig-out/bin/zig-cdp` consumer is
  never disrupted mid-build.
- Update `README.md`, `docs/cli.md`, `CURRENT_STATUS.md`, and the package version
  if appropriate; perform the final `zig build -Doptimize=ReleaseSafe` so
  `zig-out/bin/zig-cdp` is updated cleanly, verify `zig-out/bin/zig-cdp --version`
  and the new features end-to-end, and remove temporary build/test artifacts.

## Delivery and Verification

All four items are implemented in `zig-cdp 0.5.0`:

1. **Subcommand `-h` / `--help` before session/endpoint validation**: `cli.zig`
   scans arguments for `-h` / `--help` prior to requiring `--session` or
   `--endpoint`, printing concise per-command help for known subcommands
   (`protocol`, `observe`, `eval`, `screenshot`, `sequence`, etc.) or global
   usage to stdout and exiting `0`.
2. **Bounded `exceptionDetails` on `BrowserEvaluationFailed`**: `Agent.Page.eval`
   extracts a UTF-8-safe, control-normalized `EvaluationException` (`summary`
   capped at 512 bytes, optional 0-based `line` and `column`, and `truncated`)
   from both `Runtime.evaluate` and `Runtime.awaitPromise` failures, surfaced as
   `error.exception` on `eval` and `sequence` failure envelopes while preserving
   `ok`, `err`, and existing `error` fields.
3. **Repeatable `--body-method` / `--body-url` pairs in `observe`**: `observe`
   accepts up to 8 exact `(METHOD, URL)` pairs, validating matching counts,
   uppercase HTTP methods, and exact `http://` / `https://` URLs up front while
   preserving single-pair compatibility and `--body-limit` / `--max-bytes` /
   `unavailable_bodies` accounting.
4. **Scoped auto-clearing `--emulate-viewport WIDTHxHEIGHT`**: `screenshot` and
   `sequence` accept `160..7680` × `160..4320` CSS pixel dimensions, apply
   `Emulation.setDeviceMetricsOverride` (`deviceScaleFactor: 1`, `mobile: false`)
   without calling `Page.bringToFront` or resizing the OS window, and
   unconditionally run `Emulation.clearDeviceMetricsOverride` under a bounded
   500 ms cleanup deadline (restoring `1280x720` on owned headless browsers and
   flushing visual properties on non-headless hidden tabs via a brief screencast
   pulse), reporting `viewport_cleanup` (`not_needed` | `complete` | `incomplete`)
   and `ViewportCleanupIncomplete` on transport loss.

Verified with Zig `0.17.0` and Chrome `157.0.8103.38`:

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| Full native CLI on one allowed CPU (`taskset -c 0`) | 14 scenario groups passed | 14 scenario groups passed |
| Library and observer tests (`zig build test`) | 17/17 passed | 17/17 passed |
| Compile, example, and install (`zig build check example`) | passed | passed |
| Xvfb headed viewport, window bounds, and focus (`test-headed`) | 1/1 passed | 1/1 passed |
| Independent package consumer (`tests/package`) | 1/1 passed | 1/1 passed |

CLI binary SHA-256 hashes from qualification:
- Debug: `2c2f6122c612e6bf252ce6bbcf27f597bb74291360507edafbe3290f7f52d19b`
- `ReleaseSafe`: `0ebd155b565222207f836a0205581e9c4e9282340d4e5d8c85a5366cf5f32d4e`

Resource gate (`720` inspections, `36` tab cycles, `12` sequences, `12`
frame/closed-shadow cycles, and related worker observation):
- Debug owner RSS: `10,477,568 → 11,362,304` bytes; descriptors: `7 → 7`
- `ReleaseSafe` owner RSS: `4,186,112 → 4,902,912` bytes; descriptors: `7 → 7`

Note: `openbox` is not installed on this host, so `zig build test-focus` could
not launch `openbox --sm-disable`; headed background-tab viewport
emulation/restoration, OS window bounds, and foreground focus preservation were
verified under `xvfb-run` in `zig build test-headed`.

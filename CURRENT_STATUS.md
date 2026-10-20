# Current delivery

Initial standalone extraction and command-line wrapper, October 20, 2026.

Planned acceptance:

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

The CLI wrapper is the next slice. Consumer adoption is outside this delivery.

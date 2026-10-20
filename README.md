# zig-cdp

Native Chrome DevTools Protocol automation for Zig, with an owned browser API
and a command-line wrapper. Linux, Zig **0.17.0**, and an installed Chrome or
Chromium are required. The compiler version is pinned in `.zigversion`.

The reusable `cdp` module has no GUI framework dependency. Browser process
ownership comes from the sibling [`zig-process`](../zig-process) package.
Keep both repositories under the same parent directory for the supplied local
path dependency. Node.js and a browser-driver service are not required.

## Library

Run the self-contained example:

```sh
zig build example
```

It starts a fresh headless browser, creates a fixture, enters text using browser
input, clicks Save, checks the DOM, and closes the browser. See
[`examples/smoke.zig`](examples/smoke.zig) and the
[library guide](docs/library.md) for package integration and additional actions.

## Verify

```sh
zig build test check example --summary all
zig build test check example -Doptimize=ReleaseSafe --summary all
```

The compiler uses `-O debug` and `-O safe` for direct compiler invocations;
`zig build` uses `-Doptimize=Debug` and `-Doptimize=ReleaseSafe`.
See [CURRENT_STATUS.md](CURRENT_STATUS.md) for finite verification evidence and
[DESIGN.md](DESIGN.md) for ownership and delivery boundaries.

## Source basis

The protocol, locators, and initial journey fixtures were extracted from zg-gui
commit `f0cbdc4302787cf1fa576f95b77ae1887545261c`. This package adds independent
build metadata, process ownership, and its own command-line interface. The
original consumer remains unchanged; adoption is a separate task.

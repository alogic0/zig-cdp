# zig-cdp

Native Chrome DevTools Protocol automation for Zig, with an owned browser API
and a command-line wrapper. Linux, Zig **0.17.0**, and an installed Chrome or
Chromium are required. The compiler version is pinned in `.zigversion`.

The reusable `cdp` module has no GUI framework dependency. Browser process
ownership comes from the sibling [`zig-process`](../zig-process) package.
Keep both repositories under the same parent directory for the supplied local
path dependency. Node.js and a browser-driver service are not required.

## Command line

Build once:

```sh
zig build -Doptimize=ReleaseSafe
```

The executable is `zig-out/bin/zig-cdp`. Start a session in one terminal, using a
directory that does not yet exist:

```sh
./zig-out/bin/zig-cdp --session /tmp/cdp-demo serve \
  --allow http://127.0.0.1:4180
```

After the JSON readiness message, use another terminal to control that browser:

```sh
./zig-out/bin/zig-cdp --session /tmp/cdp-demo open http://127.0.0.1:4180/
./zig-out/bin/zig-cdp --session /tmp/cdp-demo eval 'document.title'
./zig-out/bin/zig-cdp --session /tmp/cdp-demo screenshot /tmp/page.png
./zig-out/bin/zig-cdp --session /tmp/cdp-demo close
```

Start your web application separately. All commands share one page until you
close the session. Use `serve --headed` for a visible browser. `--help` lists
commands; the [CLI guide](docs/cli.md) includes a complete example without a
server, JSON results, uploads/downloads, and session cleanup.

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
zig build test-cli --summary all
zig build test-cli -Doptimize=ReleaseSafe --summary all
```

The CLI acceptance tests use Python 3's standard library. The library and CLI
have no Python runtime dependency. The independent package check runs with
`zig build test` from `tests/package` in either optimization profile.

The compiler uses `-O debug` and `-O safe` for direct compiler invocations;
`zig build` uses `-Doptimize=Debug` and `-Doptimize=ReleaseSafe`.
See [CURRENT_STATUS.md](CURRENT_STATUS.md) for finite verification evidence and
[DESIGN.md](DESIGN.md) for ownership and delivery boundaries.

## Source basis

The protocol, locators, and initial journey fixtures were extracted from zg-gui
commit `f0cbdc4302787cf1fa576f95b77ae1887545261c`. This package adds independent
build metadata, process ownership, and its own command-line interface. The
original consumer remains unchanged; adoption is a separate task.

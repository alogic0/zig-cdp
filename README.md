# zig-cdp

Native Chrome DevTools Protocol automation for Zig, with an owned browser API
and a command-line wrapper. Linux, Zig **0.17.0**, and an installed Chrome or
Chromium are required. The compiler version is pinned in `.zigversion`.

The reusable `cdp` module has no GUI framework dependency. Browser process
ownership comes from the sibling [`zig-process`](../zig-process) package.
Keep both repositories under the same parent directory for the supplied local
path dependency. Node.js and a browser-driver service are not required.

## For agents

Use the **CLI through shell/exec tools** for browser control. You do not need to
write or compile a Zig program for each task. This executable is not an MCP
server. Build it once with `zig build -Doptimize=ReleaseSafe` from this repository
if `zig-out/bin/zig-cdp` is missing. Run `zig-out/bin/zig-cdp --help` to discover
the available commands.

### Start and retain a session

Record three absolute paths in your task state:

- `cdp_bin`: this repository's `zig-out/bin/zig-cdp` executable.
- `cdp_artifacts`: a fresh temporary directory you create, for example with
  `mktemp -d /tmp/zig-cdp-agent.XXXXXX`.
- `cdp_session`: `cdp_artifacts` plus `/session`. This child directory **must not
  exist yet**; `serve` creates it.

The examples below use these names as shell variables. If separate tool calls
start fresh shells, set them again or substitute the recorded absolute paths.
Keep the same `cdp_session` for every command in the workflow.

Start the owner with your shell tool's persistent-process or terminal facility:

```sh
"$cdp_bin" --session "$cdp_session" serve
```

Retain the returned process/terminal handle. `serve` remains running; readiness
is a stdout JSON record containing `"ok":true` and `"ready":true`, **not process
exit**. Wait for that record before issuing client commands from another tool
call. A short-lived exec environment that kills the owner on return cannot
support this workflow. Do not put blocking `serve` before client commands in the
same sequential shell script.

For a real application, start its server separately, run `allow ORIGIN` for the
page/API/asset origins it needs, and then `open URL`. Origins have no path or
trailing slash. For example, allow `http://127.0.0.1:4180` before opening
`http://127.0.0.1:4180/`. Add redirect origins when needed. After navigation, use
`wait` for an application-specific ready condition.

### Inspect, act, and verify

For a self-contained practice session, create this fixture. `content` replaces
the document; use `open` when working with an actual application.

```sh
"$cdp_bin" --session "$cdp_session" content '<label>Name<input id="name"></label><button id="save">Save</button><p id="result"></p>'
"$cdp_bin" --session "$cdp_session" eval 'document.querySelector("#save").onclick=()=>document.querySelector("#result").textContent=document.querySelector("#name").value; true'
```

Inspect the DOM to discover selectors before acting. Return JSON-compatible
data, keep inspection bounded, and query additional attributes when needed:

```sh
"$cdp_bin" --session "$cdp_session" eval 'Array.from(document.querySelectorAll("button,input,select,textarea,a")).filter(e=>e.getClientRects().length && getComputedStyle(e).visibility!=="hidden").slice(0,80).map(e=>({tag:e.tagName,id:e.id,testId:e.getAttribute("data-testid"),text:(e.innerText||e.getAttribute("aria-label")||"").trim().slice(0,120),type:e.getAttribute("type"),disabled:e.matches(":disabled")}))'
```

The CLI's element commands accept **CSS selectors**. Selectors should resolve to
one intended element; use observed IDs, test attributes, or scoped selectors.
There is no CLI accessibility-tree snapshot command. If you need visual context,
save a screenshot and open the returned local PNG path with your image-viewing
tool; the command's JSON reply does not itself display an image.

Using the IDs observed in the fixture:

```sh
"$cdp_bin" --session "$cdp_session" fill '#name' 'Sample'
"$cdp_bin" --session "$cdp_session" click '#save'
"$cdp_bin" --session "$cdp_session" wait 'document.querySelector("#result")?.textContent === "Sample"'
"$cdp_bin" --session "$cdp_session" text '#result'
"$cdp_bin" --session "$cdp_session" screenshot "$cdp_artifacts/result.png"
```

Check each command's exit status and JSON `ok` field before continuing. `text`
should return `{"ok":true,"result":"Sample"}`. A successful `eval` returning
`false` means the expression evaluated successfully, not that your assertion
passed. Check its `result`, or use `wait` for an expected condition. Verify the
effect after each meaningful action; dispatching a click does not establish
that the application completed its work.

On `OriginNotAllowed`, add the required origin with `allow`. On
`ElementNotActionable` or a wait timeout, inspect the current DOM/screenshot
before retrying. A failed wire connection or `SessionFailed` requires closing
the session and starting a new one. If the owner exited, use a fresh session;
session state is not restored automatically. See the
[CLI guide](docs/cli.md#results-and-failures) for limits and error behavior.

### Finish

Always close the session, including when the task fails:

```sh
"$cdp_bin" --session "$cdp_session" close
```

`close` acknowledges the shutdown request. Wait for the retained owner process
to exit; it removes its browser profile, control socket, and session directory.
If commands cannot reach it, terminate **your recorded owner process** with
SIGTERM and wait for it. Keep or remove your artifact directory according to the
task. Sessions otherwise expire after 900 seconds without client activity.

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

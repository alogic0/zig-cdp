# CLI browser sessions

Build with the pinned Zig compiler using `zig build -Doptimize=ReleaseSafe`.
Use `zig-out/bin/zig-cdp` directly or install with a prefix of your choice:
`zig build -Doptimize=ReleaseSafe --prefix /your/prefix`.
Restart `serve` to pick up commands added by a rebuild; existing owners continue
running their original code.

## A complete session

In terminal one, start the owner process. Choose a directory that does not
already exist:

```sh
./zig-out/bin/zig-cdp --session /tmp/cdp-demo serve
```

It prints a JSON readiness record with the browser version, owned browser PID,
profile, `persistent_profile` flag, free loopback `port`, and session directory.
Keep this process running. In terminal two:

```sh
cdp=./zig-out/bin/zig-cdp
session=/tmp/cdp-demo

"$cdp" --session "$session" content '<label>Name<input id="name"></label><button id="save">Save</button><p id="result"></p>'
"$cdp" --session "$session" eval 'document.querySelector("#save").onclick=()=>document.querySelector("#result").textContent=document.querySelector("#name").value; true'
"$cdp" --session "$session" fill '#name' 'Sample'
"$cdp" --session "$session" click '#save'
"$cdp" --session "$session" text '#result'
"$cdp" --session "$session" screenshot /tmp/cdp-example.png
"$cdp" --session "$session" close
```

The `text` command prints `{"ok":true,"result":"Sample"}`. Commands run in
separate processes and act on the selected tab, preserving its variables and DOM.
This fixture needs no web server. By default a session uses a fresh browser
profile and isolated context.

## Use an existing profile

Pass the existing Chrome user-data directory to preserve login state:

```sh
./zig-out/bin/zig-cdp --session /tmp/cdp-saved serve --headed \
  --user-data-dir /absolute/path/to/profile --allow https://app.example
```

Then run `open https://app.example/` against `/tmp/cdp-saved`. The CLI controls
the startup blank tab in the profile's normal context, using its cookies and
local storage. It does not create an extra incognito window. Existing restored
tabs are left in place. The profile must exist and be unlocked; close Chrome
using it first. `ProfileInUse` leaves an existing lock untouched, including a
stale lock that needs manual inspection. This launches an owned Chrome process;
it does not attach to an already-running Chrome instance.

Chrome selects a free port with `--remote-debugging-port=0`, bound to loopback.
Both readiness and `status` report `port`, `profile`, and `persistent_profile`.
No fixed port or stale `DevToolsActivePort` is reused. `close`, signals, launch
failures, and idle expiry preserve the supplied profile. Download staging uses
a separate private temporary directory. Normal browser activity still updates
the profile, and the CLI closes its owned browser when the session ends.

## Navigate your application

Start the application's web server separately. With a running session (start a
new one if you closed the example above), allow its origin, then navigate:

```sh
"$cdp" --session "$session" allow http://127.0.0.1:4180
"$cdp" --session "$session" open http://127.0.0.1:4180/
"$cdp" --session "$session" wait 'document.querySelector("#app") !== null'
```

You can also repeat `--allow ORIGIN` when starting `serve`. Add API, asset, and
redirect origins as needed. Origins have no path or trailing slash. Hostnames
must match browser URLs: `localhost` differs from `127.0.0.1`. Use canonical
origins (for example, omit the default `:80` for HTTP and `:443` for HTTPS).
The CLI rejects navigation to an unlisted HTTP(S) origin with `OriginNotAllowed`.
Page interception blocks other unlisted requests. `about:blank`, `data:`, and
`blob:` are allowed. This is page interception, not network containment of the
whole browser process.

## Tabs

```sh
"$cdp" --session "$session" tabs
"$cdp" --session "$session" new-tab
"$cdp" --session "$session" new-tab http://127.0.0.1:4180/
```

`tabs` returns an array of `{id,title,url,selected}` objects. The `id` is Chrome's
stable target ID, not an index. `new-tab` accepts zero or one URL, selects the new
tab, and returns its object in the same shape. A supplied URL must already be
allowed, just like `open`; a denied URL creates no tab.

Record an ID from the JSON response as `tab_id` and pass it to:

```sh
"$cdp" --session "$session" switch-tab "$tab_id"
"$cdp" --session "$session" eval 'document.title'
"$cdp" --session "$session" close-tab "$tab_id"
```

`switch-tab` brings the tab forward and directs subsequent page commands to it.
Its response is `{id,title,url,selected:true}`. It attaches to an existing page
without reloading it, so DOM state and form values remain. `status.tab_id` also
reports the selected ID. Selection belongs to the CLI: manually clicking another
Chrome tab does not change which tab a later CLI command controls.

Use `new-tab [URL] --background` to create the tab without activating it.
It still becomes the owned session's CLI-selected tab. `switch-tab ID
--background` changes only that selection. Explicit `--tab ID` page commands
attach without activation, as do automatic selection recovery and last-tab
replacement. This intentionally removes implicit foreground changes from
recovery. Chrome may select another tab when a visible tab closes; the CLI does
not request window activation. Initial window creation and native dialogs can
still affect focus.

`close-tab [ID]` closes only that tab; omitting ID uses the selected tab. The
reply is `{closed:ID,selected:ID}`. Closing an inactive tab preserves selection;
closing the selected tab selects a surviving tab. Closing the final tab first
creates a blank replacement to keep the browser and shared context alive.
`close` still shuts down the whole browser session.

Only page targets in the session's browser context are listed and selectable.
Temporary sessions share one isolated context. Saved-profile sessions use the
default context and can list/select tabs opened manually or restored by Chrome.
Browser UI, workers, other contexts, and other browser sessions are excluded.
Unknown, closed, or out-of-context IDs fail with `TabNotFound`.

All tabs in this context share cookies and origin storage. `allow` and `timeout`
apply to existing controlled tabs and later attachments. Interception starts
when the CLI attaches to a tab. Between commands the owner pumps every attached
page, including inactive tabs, so their background requests can finish. Commands
remain serial; a long-running command postpones servicing other pages. A tab
closed externally is removed and a surviving tab is selected automatically; if
Chrome itself exits, start a new session.

## Commands

Put `--session PATH` before the command. Quote CSS, HTML, and JavaScript so the
shell passes each as one argument. Existing positional CSS commands remain valid.

Element commands also accept one named locator: `--selector CSS`,
`--role ROLE [--name EXACT_NAME]`, or `--text EXACT_TEXT`. Role/name matching
uses Chrome's accessibility tree. Text matching normalizes whitespace and selects
the deepest exact matches. Missing and ambiguous targets return distinct errors;
the tool never silently chooses the first match.

```sh
"$cdp" --session "$session" snapshot --limit 20000
"$cdp" --session "$session" read --limit 10000
"$cdp" --session "$session" fill --role textbox --name Name --value Sample
"$cdp" --session "$session" click --role button --name Save
"$cdp" --session "$session" select --role combobox --name Choice --value b
"$cdp" --session "$session" press --selector '#name' --key Control+a
"$cdp" --session "$session" wait --selector '#result' --state visible --timeout 5000
```

`read` returns UTF-8 text, byte counts and an explicit `truncated` flag.
`snapshot` returns accessibility nodes with IDs, roles, names, values, states,
parent IDs and backend DOM IDs. Its byte budget covers serialized nodes; the
small JSON envelope is additional. Both default to 20,000 bytes and accept
`--limit` from 1 to 1,048,576. Snapshot node IDs are observations of the current
document and must be refreshed after navigation. Neither locator type promises
iframe or shadow-root traversal.

`--tab ID` targets a page without changing the session's selection.
`--timeout MS` overrides the operation budget without changing the session
default. Locator waits accept `visible`, `hidden`, `attached`, or `detached`;
hidden and detached waits succeed when no element matches.

`fill` and `select` accept `--value-file PATH` or `--value-file -` to read stdin.
`eval --script PATH|-` accepts a file or stdin as an alternative to inline code.
Input files are limited to 1 MiB; trailing newlines are preserved. Use `--` before
positional arguments that begin with two hyphens. `--out PATH` saves command JSON
to a private file. Screenshots accept `--out PATH` and either `--viewport` or
`--full-page`; a full-page capture uses the document's content dimensions and
excludes browser scrollbars. Output parent directories must exist.

Keyboard combinations accept Control/Ctrl, Alt, Meta and Shift, followed by an
ASCII character or Enter, Tab, Escape, Backspace, Delete, ArrowLeft/Up/Right/Down,
Home, End, PageUp, PageDown, or Space. Input and mouse actions use CDP browser
input. Selecting an option dispatches DOM input/change events.

| Command | Behavior |
| --- | --- |
| `status` | Return browser version, selected `tab_id`, URL, origins, timeout, profile, and CDP port. |
| `tabs` | List tab IDs, titles, URLs, and CLI selection in this context. |
| `new-tab [URL]` | Create and select a tab; defaults to `about:blank`. |
| `switch-tab ID` | Select an existing tab without reloading it. |
| `close-tab [ID]` | Close one tab; defaults to the selected tab. |
| `allow ORIGIN` | Add an origin for all controlled tabs in this session. |
| `open URL` | Navigate and wait for the new document to finish loading. |
| `reload` | Reload the current page. |
| `content HTML` | Replace the document with fixture HTML. |
| `eval JAVASCRIPT` | Evaluate JavaScript and await a returned promise. |
| `click CSS` | Scroll, check actionability, and send browser mouse input. |
| `fill CSS TEXT` | Fill a form input using browser text input. |
| `text CSS` | Read one element's `innerText`. |
| `read [LOCATOR]` | Read bounded rendered text with truncation metadata. |
| `snapshot` | Read a bounded Chrome accessibility tree. |
| `select CSS VALUE` | Select one enabled native option. |
| `press KEY` | Send a key or modifier combination, optionally to a locator. |
| `wait JAVASCRIPT` | Wait for the expression to return boolean `true`. |
| `timeout MILLISECONDS` | Set the timeout for session tabs, from 1 to 120000. |
| `screenshot PATH` | Write a PNG. |
| `upload CSS PATH` | Set a file input to an existing local file. |
| `download CSS PATH` | Click a control and save the completed download. |
| `close` | Ask the owner to shut down and clean up. |

Headless pages use a fixed 1280 × 720 viewport. With `--headed`, the page follows
the window's available content size and native display scale, including resizes.
Use `read` and `snapshot` for bounded inspection, `eval` for additional DOM
queries, and the library for additional CDP methods, multiple contexts, or structured
HTTP response observations. A successful `eval` may return `null` for values CDP
cannot serialize by value; prefer plain JSON-compatible results. Application
assertions belong in your script: evaluating `false` is successful evaluation,
whereas `wait 'false'` eventually fails.

Paths for screenshots, uploads, and downloads are made absolute in the client
before being sent to the owner. This lets commands work from different working
directories. Parent output directories must exist. Existing outputs are
overwritten, and files outside the temporary browser profile survive shutdown.
Downloads are limited to 20 MiB; the reply reports the suggested filename,
destination path, and byte count.

## Results and failures

Each client command writes one JSON object to stdout:

```json
{"ok":true,"result":42}
```

Failures exit with status 1 and report an error name:

```json
{"ok":false,"err":"ElementNotActionable"}
```

Command errors also include an `error` object containing `code`, `phase`,
`match_count`, and `action`. The action field is `not_started`,
`possibly_dispatched`, or `completed`; it describes input dispatch, not an
application assertion. Inspect the page before repeating a write after an
uncertain result. Ordinary locator failures leave the session usable.

Diagnostics from browser operations go to the owner's stderr. A rejected command,
locator timeout, or JavaScript exception normally leaves the session usable.
If a wire connection has failed, close the session and start a new one. Do not
dump authenticated page data or request captures into logs without considering
what they contain.

The transport allows one command per connection, at most 1 MiB of request JSON
and 16 MiB of response JSON. The server allows five seconds to receive a complete
request; clients allow 180 seconds for a reply. Commands default to 30 seconds,
with `--timeout MS` overriding the budget (1..120000). Owned sessions can change
their default with `timeout MS`. Discovery, tab operations and nested CDP calls
share the budget. Final RPC reads allow 100 ms of grace, object cleanup up to
200 ms, and whole-command cancellation a 300 ms grace before joining work. Commands run
serially. The CLI is intended for trusted clients under the same user account.

## Session lifecycle

`serve` stays in the foreground. Run it in a terminal or under a supervisor you
control. Options:

```text
--allow ORIGIN          Repeat for every required origin
--browser PATH         Explicit Chrome/Chromium executable
--headed               Show the browser (requires a graphical session)
--user-data-dir PATH    Existing unlocked profile; preserved on shutdown
--idle-timeout SECONDS  Close after no client connections; default 900, max 86400
```

The owner exclusively creates a mode-0700 directory and a Unix control socket
inside it. A second owner using the same directory fails without removing the
existing session. Separate directories create isolated browser sessions.

`close`, idle expiry, Ctrl+C, and SIGTERM trigger page/browser cleanup, join the
owned browser process, and remove the temporary workspace, socket, and session
directory. A supplied user-data directory is preserved. `close`
acknowledges the shutdown request; wait for the owner process to exit before
reusing its directory. SIGKILL or machine failure cannot run cleanup. Inspect
stale directories and the PID/profile from the prior readiness record yourself;
the CLI never deletes pre-existing session directories automatically.

Results and inspection data are reclaimed after each command. Closed tab
connections release their storage. The owner retains at most 64 controlled tabs
and 128 allowed origins; exceeding these yields `TabLimitExceeded` or
`OriginLimitExceeded`. It services origin-policy events between commands without
retaining network bodies or exception histories. Journey library observation
APIs keep their separate arena-based contract.

Owned sessions allow downloads only during an explicit `download` command and
remove private staging files afterward. Capture retains at most 256 download
events/2 MiB and reads at most 20 MiB of output. Attached download capture bounds
its event stream to 4,096 events/8 MiB and leaves Chrome's default directory
unchanged. Temporary request memory is still proportional to a bounded CDP frame
(up to 64 MiB) and is released on completion. Repeated-workflow tests measure the
owner process; these limits do not bound Chrome's own page/application memory.
Headless automation and cleanup have finite test coverage. Automated Xvfb checks
cover native viewport resizing in default and isolated contexts. One X11
saved-profile window was also checked manually. These checks do not establish
all graphical session behavior or every Chrome version.

## Existing-browser attachment

Use `--endpoint http://127.0.0.1:PORT` or a loopback browser WebSocket URL in
place of `--session PATH`. HTTP discovery uses `/json/version`. Only `localhost`
and `127.0.0.1` endpoints are accepted. Authentication, URL queries, fragments,
non-root HTTP paths, and page WebSocket URLs are rejected.

`tabs`, `status`, `new-tab [URL]`, `switch-tab ID`, `close-tab ID`, and `close`
operate directly on the external browser. Every page command requires `--tab
ID`; there is no selection stored between invocations. `switch-tab` activates
that tab in Chrome. `new-tab` creates a default-context tab and returns its ID.
`close` disconnects, while `close-tab` deliberately closes the specified target.
`new-tab --background` creates a background tab. Endpoint `switch-tab
--background` fails with `EndpointRequiresExplicitTab`; use `--tab ID` on each
operation instead. Ordinary endpoint operations never request activation.
`allow`, `timeout` and `serve` are session commands; use `--timeout MS` for an
attached command's budget (30 seconds by default).

Attached inspection and actions do not change device metrics, inject persistent
helpers, set a download directory, or install background network interception.
An explicit `download LOCATOR PATH` temporarily intercepts attachment responses
to copy up to 20 MiB to PATH, then removes its interception. Blob/data downloads
are copied from the page; Chrome may also save its usual copy. Other requests
continue normally. This finite download support does not cover arbitrary
application streaming protocols. Files are created with private permissions.

Disconnect, errors, SIGINT and SIGTERM leave the external browser and its profile
alive. Page changes and explicitly created/closed tabs remain as requested.
Timeout after dispatch can leave an action in progress: inspect before retrying.
A command requiring a promise that never settles can seal its own connection;
the next endpoint command establishes a fresh connection.

## Acceptance checks

Run `zig build test-cli` or `zig build test-cli -Doptimize=ReleaseSafe` for the
native subprocess suite. Chrome is required; Python is not. The suite covers
owned sessions and external attachment, actions and output files, tabs and saved
profiles, malformed requests, discovery faults, signals and timeout recovery.
It retains the 720-command/36-tab resource workload and verifies canceled
downloads stop receiving data and remove staging. Tests use fresh private
profiles and ephemeral loopback ports. `zig build test-headed` separately checks
native window sizing under Xvfb.

See the [scenario map](plans/2026-10-21-native-cli-migration.md) for the preserved
reference coverage and parity evidence.

## Observation across commands

Start `observe` in a retained foreground process, read its stdout readiness
record (`ok:true, ready:true`), then issue actions from separate processes:

```sh
zig-cdp --endpoint "$endpoint" observe --tab "$tab_id" \
  --events console,exceptions,network --duration 30000 --out "$capture" \
  --body-method POST --body-url 'https://example.test/api/save'
# After readiness, from another shell/tool invocation:
zig-cdp --endpoint "$endpoint" click --tab "$tab_id" --role button --name Save
```

The same syntax works with `--session PATH`. An explicit tab is required; the
owner resolves it once and the observer borrows an independent connection.
Observation does not occupy the owner's command loop, install interception,
change download paths, replay requests or acquire browser ownership. Workers
and separate frame targets are outside this capture scope. Existing owner
origin restrictions remain active.

`--out` must name a new file, created with mode 0600. It contains JSON Lines,
version 1, with `tab`, increasing `seq`, Unix `observed_ms`, `kind`, and `data`.
Kinds include console, exception, request, response, redirect, finished, failed,
and body. Network records correlate `request_id` and redirect `hop`; request and
response records include frame/loader IDs when available. CDP timestamps retain
their original units (network seconds, Runtime milliseconds). Console records
include bounded argument descriptions and the first source location; objects
are not recursively expanded. Metadata omits headers, credentials, query,
fragment and payloads. Console/exception text itself may contain secrets.

Both `--body-method` (uppercase) and `--body-url` (exact full HTTP(S) URL,
including query) are required for body capture. Matching is done before URL
redaction. Bodies are retrieved after completion, never by repeating the
request. A body record reports `complete`, `unavailable`, `oversized`, or
`binary`; only complete UTF-8 text is emitted. Chrome can evict a body before
retrieval. Downloads can be observed but do not promise readable response bodies.

Limits (options may lower these ceilings):

| Option | Default | Ceiling |
| --- | --- | --- |
| `--duration` milliseconds | 30000 | 120000 |
| `--max-events` output records | 4096 | 4096 |
| `--max-bytes` capture bytes | 8388608 | 8388608 |
| `--body-limit` decoded body bytes | 1048576 | 1048576 |

At most 4096 active requests are retained. Individual incoming events are
limited to 2 MiB; metadata output records to 64 KiB. Console text is limited to
4096 bytes and 32 arguments. The transport's existing 64 MiB frame bound also
applies. Per-round-trip storage is reclaimed; this does not bound Chrome's
application memory. There is a six-second startup allowance around the finite
capture duration. Expiry is successful completion; interrupted/disconnected,
failed output, overflow, truncated text or unavailable requested bodies produce
a nonzero result. Limits stop capture rather than silently dropping an unlimited
stream. Stdout ends with a summary containing `reason`, record/byte counts,
`dropped`, `truncated`, and `unavailable_bodies`. This readiness + summary stream
is the exception to the ordinary one-result stdout contract. SIGINT/SIGTERM
release only observer sockets and preserve the browser and partial file.

## Held input and sequences

`drag SOURCE_CSS DESTINATION_CSS` resolves strict, stable, enabled, uncovered
controls, holds the left button, moves incrementally and releases it. Semantic
locators work with `--selector`/`--role`/`--text` for the source and
`--to-selector`/`--to-role`/`--to-name`/`--to-text` for the destination.
`--hold MS` defaults to 300 (maximum 10000); `--steps N` defaults to 12 (2–120).
Movement steps are separated by 16 ms, within the overall command deadline.
Background input temporarily enables page focus emulation and compositor frames;
these are cleared on completion. It does not activate Chrome's tab/window or
change viewport metrics. Application focus/visibility callbacks can run during
this emulation. Drag geometry is local to the page, never desktop coordinates.

`protocol METHOD --params FILE|-` accepts a JSON object (default `{}`). The
initial supported methods are `Input.dispatchMouseEvent`,
`Input.dispatchKeyEvent`, `Input.insertText`, `DOM.getDocument`,
`DOM.querySelector`, `DOM.querySelectorAll`, `DOM.getBoxModel`,
`Page.getLayoutMetrics`, and `Accessibility.getFullAXTree`. Parameters and method
scope are validated before dispatch. Mouse input supports moved/pressed/released/
wheel events, left/right/middle buttons, coordinates, buttons, clickCount,
modifiers and wheel deltas. Key input supports type/key/code/text/unmodifiedText,
virtual key codes, modifiers, repeat/keypad/system flags and location. DOM tree
depth is capped at 32; piercing and browser/context lifecycle calls are excluded.
Use typed `open`, `new-tab`, `close-tab` and `close` for lifecycle operations.

Use `sequence --file FILE|- --timeout MS` to retain one connection and input
state across steps. Example file:

```json
{"version":1,"steps":[
  {"command":"fill","locator":{"role":"textbox","name":"Name"},"args":["Sample"]},
  {"command":"protocol","args":["Input.dispatchKeyEvent"],"params":{"type":"keyDown","key":"Shift","code":"ShiftLeft","windowsVirtualKeyCode":16}},
  {"command":"pause","args":["150"]},
  {"command":"protocol","args":["Input.dispatchKeyEvent"],"params":{"type":"keyUp","key":"Shift","code":"ShiftLeft","windowsVirtualKeyCode":16}},
  {"command":"click","locator":{"role":"button","name":"Save"}},
  {"command":"read"}
]}
```

The document is at most 1 MiB and contains 1–128 steps, all checked before
execution. Step fields match command requests: `command`, string-array `args`,
optional `locator`, `destination`, `hold_ms`, `steps`, `params`, `limit`, `state`,
and `full_page`. Step-local tabs, deadlines, background flags, nested sequences,
owner commands and downloads are rejected. Supported named steps are open,
reload, content, eval, click, fill, text, read, snapshot, select, press, wait,
screenshot, upload and drag; protocol and pause complete the list. A pause is
0–10000 ms. Relative file paths resolve against the invoking client. There is
one overall deadline and an 8 MiB result budget. No loops, branching, host code,
result binding or automatic replay are provided. Validation cannot predict
future page state; actionability is checked when each step executes.

Results contain per-step results and zero-based step reports. A failure includes
`error.step`, reports for every step (`action` and optional `err`), and
`input_release`: `not_needed`, `complete`, or `incomplete`. Later steps remain
`not_started`. Cleanup attempts mouse/key release on the same target for up to
200 ms; a lost connection reports incomplete release without replacing the
original error. Up to one mouse button and 16 keys may be held. Outstanding
input is also released at successful sequence completion; use a sequence to
hold input between calls. Endpoint SIGINT/SIGTERM cancels and performs this
cleanup. Disconnecting an owned drag/sequence client cancels its in-flight work
and releases input. Inspect page state and step reports before retrying a write.

## Multiple-file upload

```sh
zig-cdp --endpoint "$endpoint" upload --tab "$tab_id" --selector 'input[type=file]' \
  --file './first file.txt' --file './другий файл.txt'
```

Repeat `--file` for 1–64 regular readable files, at most 32 KiB of total path
text. Paths resolve in the invoking client's working directory. The complete
list is validated before changing the control; one `DOM.setFileInputFiles` call
replaces its existing selection, preserving supplied order. Hidden file inputs
are supported; disabled inputs, non-file controls and ambiguous locators fail.
More than one file requires the control's `multiple` attribute. Positional
`upload CSS PATH` and `upload LOCATOR PATH` remain supported; do not mix positional
files with `--file`. Sequence upload steps accept a `files` array instead of
positional file arguments. Every sequence file list is checked before its first
step; Chrome opens the files when the upload runs.

See the [complete native browser workflow](browser-workflow.md) for the combined
scenario, verification commands and consumer adoption boundary.

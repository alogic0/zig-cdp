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

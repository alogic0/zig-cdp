# CLI browser sessions

Build with the pinned Zig compiler using `zig build -Doptimize=ReleaseSafe`.
Use `zig-out/bin/zig-cdp` directly or install with a prefix of your choice:
`zig build -Doptimize=ReleaseSafe --prefix /your/prefix`.

## A complete session

In terminal one, start the owner process. Choose a directory that does not
already exist:

```sh
./zig-out/bin/zig-cdp --session /tmp/cdp-demo serve
```

It prints a JSON readiness record with the browser version, owned browser PID,
profile, and session directory. Keep this process running. In terminal two:

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
separate processes but share the same browser page, variables, cookies, and DOM.
This fixture needs no web server. A session owns a fresh browser profile; it does
not use your normal browsing profile.

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

## Commands

Put `--session PATH` before the command. Quote CSS, HTML, and JavaScript so the
shell passes each as one argument. All element commands use CSS selectors.

| Command | Behavior |
| --- | --- |
| `status` | Return browser version, current URL, origins, and page timeout. |
| `allow ORIGIN` | Add an origin to this page's allowlist. |
| `open URL` | Navigate and wait for the new document to finish loading. |
| `reload` | Reload the current page. |
| `content HTML` | Replace the document with fixture HTML. |
| `eval JAVASCRIPT` | Evaluate JavaScript and await a returned promise. |
| `click CSS` | Scroll, check actionability, and send browser mouse input. |
| `fill CSS TEXT` | Fill a form input using browser text input. |
| `text CSS` | Read one element's `innerText`. |
| `wait JAVASCRIPT` | Wait for the expression to return boolean `true`. |
| `timeout MILLISECONDS` | Set the page timeout, from 1 to 120000. |
| `screenshot PATH` | Write a PNG. |
| `upload CSS PATH` | Set a file input to an existing local file. |
| `download CSS PATH` | Click a control and save the completed download. |
| `close` | Ask the owner to shut down and clean up. |

The browser starts at 1280 × 720. Use `eval` for DOM inspection and the library
for additional CDP methods, role/name locators, multiple contexts, or structured
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

Diagnostics from browser operations go to the owner's stderr. A rejected command,
locator timeout, or JavaScript exception normally leaves the session usable.
If a wire connection has failed, close the session and start a new one. Do not
dump authenticated page data or request captures into logs without considering
what they contain.

The transport allows one command per connection, at most 1 MiB of request JSON
and 16 MiB of response JSON. The server allows five seconds to receive a complete
request; clients allow 180 seconds for a reply. Page waits default to 30 seconds,
and individual CDP socket reads have their own 30-second timeout. Commands run
serially. The CLI is intended for trusted clients under the same user account.

## Session lifecycle

`serve` stays in the foreground. Run it in a terminal or under a supervisor you
control. Options:

```text
--allow ORIGIN          Repeat for every required origin
--browser PATH         Explicit Chrome/Chromium executable
--headed               Show the browser (requires a graphical session)
--idle-timeout SECONDS  Close after no client connections; default 900, max 86400
```

The owner exclusively creates a mode-0700 directory and a Unix control socket
inside it. A second owner using the same directory fails without removing the
existing session. Separate directories create isolated browser sessions.

`close`, idle expiry, Ctrl+C, and SIGTERM trigger page/browser cleanup, join the
owned browser process, and remove the socket and session directory. `close`
acknowledges the shutdown request; wait for the owner process to exit before
reusing its directory. SIGKILL or machine failure cannot run cleanup. Inspect
stale directories and the PID/profile from the prior readiness record yourself;
the CLI never deletes pre-existing session directories automatically.

Browser observations and values stay in an arena for the session's lifetime.
Close and restart between long workflows; this version is intended for finite
automation sessions rather than an indefinite browser daemon. The owner services
browser events between commands so background requests can finish while idle.
Headless automation and cleanup have finite test coverage; visible-window
behavior and every Chrome version are not established by those tests.

# Native browser workflow

The CLI can complete the local browser workflow without a Zig, Python or Node
controller. The native acceptance scenario starts observation before navigation,
inspects controls, fills/saves, checks the actual matching POST response and the
rendered result, drags a card, uploads two files, downloads an artifact, reloads,
captures a screenshot and disconnects. It verifies a sentinel tab's unsaved
form, viewport and external browser/profile survival. Reproduce it with:

```sh
zig build test-cli -- --case workflow
zig build test-cli -Doptimize=ReleaseSafe -- --case workflow
# Also preserve a competing foreground window, using private Xvfb/Openbox:
zig build test-focus
zig build test-focus -Doptimize=ReleaseSafe
```

The fixture, files, profiles, HTTP ports and browser processes belong to the
tests. These commands do not use your desktop browser. A consumer workflow can
adopt the same command sequence after checking its own routes and controls.

## Attach and record explicit targets

Use the existing browser/profile and discover its live endpoint. When Chrome
was launched with a dynamic debugging port and writes `DevToolsActivePort`, the
first line identifies that port:

```sh
# From this repository, build once and retain the absolute executable path:
zig build -Doptimize=ReleaseSafe
cdp_bin="$PWD/zig-out/bin/zig-cdp"
profile='/path/to/the/existing/profile'
read -r port < "$profile/DevToolsActivePort"
endpoint="http://127.0.0.1:$port"
"$cdp_bin" --endpoint "$endpoint" status
"$cdp_bin" --endpoint "$endpoint" tabs
"$cdp_bin" --endpoint "$endpoint" new-tab --background
```

Record the returned `result.id` as `tab_id`. For a browser launched with an
explicit debugging port, use its verified launch configuration instead of an
old endpoint file. Keep endpoint, tab ID and output paths in the agent's task
state across fresh shell calls. Endpoint attachment adds no origin interception
and never takes ownership of the browser process.

## Observe before acting

Choose the exact response URL and HTTP method from the application's documented
or inspected behavior. Make a private output directory and choose a new file:

```sh
capture_dir=$(mktemp -d)
capture="$capture_dir/events.jsonl"
"$cdp_bin" --endpoint "$endpoint" observe --tab "$tab_id" \
  --duration 30000 --out "$capture" --events console,exceptions,network \
  --body-method POST --body-url "$save_url"
```

Retain that process with the agent's process tool. Wait for its stdout record
with `ready:true` before issuing actions through separate invocations. Capture
and response bodies have explicit limits; see [the observer contract](cli.md#observation-across-commands).

```sh
"$cdp_bin" --endpoint "$endpoint" open "$page_url" --tab "$tab_id"
"$cdp_bin" --endpoint "$endpoint" snapshot --tab "$tab_id"
# Use the role/name or selectors actually returned by inspection:
"$cdp_bin" --endpoint "$endpoint" fill --tab "$tab_id" \
  --role textbox --name Name --value Ada
"$cdp_bin" --endpoint "$endpoint" click --tab "$tab_id" \
  --role button --name Save
"$cdp_bin" --endpoint "$endpoint" wait --tab "$tab_id" --text 'Saved Ada'
"$cdp_bin" --endpoint "$endpoint" drag --tab "$tab_id" \
  --selector '#card' --to-selector '#drop' --hold 150 --steps 8
"$cdp_bin" --endpoint "$endpoint" upload --tab "$tab_id" \
  --selector 'input[type=file]' --file './first file.txt' --file './second file.txt'
"$cdp_bin" --endpoint "$endpoint" download --tab "$tab_id" \
  --role link --name 'Download artifact' "$capture_dir/artifact.txt"
"$cdp_bin" --endpoint "$endpoint" reload --tab "$tab_id"
"$cdp_bin" --endpoint "$endpoint" screenshot --tab "$tab_id" \
  --full-page "$capture_dir/page.png"
```

The controls above match the native fixture; adapt them to observed application
controls. Read the capture as JSON Lines. Join a POST `request` to `response`,
`finished` and `body` by `request_id` and redirect `hop`; check status and
`body.availability:"complete"`, then parse `body.text`. Verify the intended
response fields and rendered UI. Do not infer save success from the click's
exit status alone. Wait for the observer's final summary and require `ok:true`
for complete evidence within its capture interval. A nonzero/partial result
requires inspecting its explicit reason and counters.

```sh
"$cdp_bin" --endpoint "$endpoint" close
```

This disconnect leaves the visible browser and task tab available for inspection.
Use explicit `close-tab ID` only when that tab should be removed. Initial window
creation and native dialogs can still change desktop focus. Background actions
use temporary page focus emulation; they never inject desktop input or request
window activation.

For an owned session, use `--session PATH` and configure each required origin
with `serve --allow ORIGIN` or `allow ORIGIN`. `observe` still requires an explicit
tab and uses a separate borrowed connection. Session `close` stops the owned
browser; it is not the endpoint disconnect operation. Application credentials,
authorization, routes and business rules remain in the consumer.

## Evidence and adoption boundary

The complete suite includes both ownership modes, a headed native-focus check,
single-CPU scheduling, interruption and failure recovery. Resource acceptance
retains its 24-command warmup, 720 inspection/evaluation commands, 36 tab cycles,
32 MiB owner-RSS growth limit and descriptor ceiling. It adds twelve sequences
and one independent observer without relaxing those limits. This measures the
CLI owner under that finite workload, not Chrome application memory or indefinite
observer lifetime. Observer duration, active requests, record count, individual
records and output bytes have separate hard bounds.

The external task-resolution workflow is intentionally unchanged by this
repository update. Consumer adoption should preserve the exact existing profile,
discover the live endpoint, use explicit tab IDs, and keep the window open for
inspection. Historical Playwright controllers require their own adaptation.

#!/usr/bin/env python3
"""Exercise the installed command interface across independent processes."""
import http.server
import json
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

EXE = str(Path(sys.argv[1]).resolve())


def command(session, *args, ok=True, cwd=None):
    result = subprocess.run(
        [EXE, "--session", str(session), *args],
        capture_output=True, text=True, timeout=20, cwd=cwd,
    )
    reply = json.loads(result.stdout)
    assert reply["ok"] == ok, (args, result.returncode, reply, result.stderr)
    assert (result.returncode == 0) == ok, (args, result.returncode, reply)
    return reply.get("result") if ok else reply["err"]


class Session:
    def __init__(self, path, *options):
        self.path = path
        self.log = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [EXE, "--session", str(path), "serve", *options],
            stdout=subprocess.PIPE, stderr=self.log, text=True,
        )
        try:
            ready, _, _ = select.select([self.process.stdout], [], [], 20)
            assert ready, "session startup timeout"
            self.ready = json.loads(self.process.stdout.readline())
            assert self.ready.get("ready"), self.ready
        except BaseException:
            self.abort()
            raise

    def done(self):
        assert self.process.wait(timeout=10) == 0
        assert not self.path.exists(), self.path
        assert Path(self.ready["profile"]).is_dir() == self.ready["persistent_profile"], self.ready
        assert not Path(f'/proc/{self.ready["pid"]}').exists(), self.ready

    def abort(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process.stdout.close()
        self.log.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.abort()


def raw_request(session, payload):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10)
        sock.connect(str(session / "control.sock"))
        sock.sendall(payload)
        with sock.makefile("rb") as reader:
            return json.loads(reader.readline())


def page_targets(server):
    with urllib.request.urlopen(f'http://127.0.0.1:{server.ready["port"]}/json/list', timeout=5) as reply:
        return [target for target in json.load(reply) if target["type"] == "page"]


def browser_request(server, path, method="GET"):
    request = urllib.request.Request(f'http://127.0.0.1:{server.ready["port"]}' + path, method=method)
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.read()


def exercise_tabs(server, origin, root):
    session = server.path
    original = command(session, "tabs")
    assert len(original) == 1 and original[0]["selected"], original
    first = original[0]["id"]
    assert command(session, "status")["tab_id"] == first
    for args in (("tabs", "extra"), ("new-tab", "one", "two"), ("switch-tab",), ("close-tab", "one", "two")):
        assert command(session, *args, ok=False) == "WrongArgumentCount"
    command(session, "content", '<title>First tab</title><input id="name"><p id="value">first</p>')
    command(session, "fill", "#name", "kept in first")
    command(session, "eval", "localStorage.setItem('tabs-shared','yes'); document.cookie='tabs_shared=yes; Max-Age=3600; SameSite=Lax'; true")
    command(session, "timeout", "5000")
    second = command(session, "new-tab", origin + "/")["id"]
    assert second != first
    assert command(session, "status")["timeout_ms"] == 5000
    assert command(session, "eval", "localStorage.getItem('tabs-shared')") == "yes"
    assert command(session, "eval", "document.cookie.includes('tabs_shared=yes')") is True
    command(session, "content", '<title>Second tab</title><input id="name"><p id="value">second</p>')
    command(session, "fill", "#name", "kept in second")
    listed = command(session, "tabs")
    assert {tab["title"] for tab in listed} == {"First tab", "Second tab"}
    assert [tab["id"] for tab in listed if tab["selected"]] == [second]
    assert command(session, "switch-tab", first)["id"] == first
    assert command(session, "text", "#value") == "first"
    assert command(session, "eval", "document.querySelector('#name').value") == "kept in first"
    assert command(session, "status")["timeout_ms"] == 5000
    assert command(session, "switch-tab", second)["id"] == second
    assert command(session, "text", "#value") == "second"
    assert command(session, "eval", "document.querySelector('#name').value") == "kept in second"

    # A later allow command must update every attached page, including inactive
    # ones. Its delayed request must complete while the owner is idle on a peer.
    other_origin = origin.replace("127.0.0.1", "localhost")
    command(session, "allow", other_origin)
    Fixture.background_seen.clear()
    command(session, "eval", f"setTimeout(() => fetch({json.dumps(other_origin + '/background')}), 200); true")
    command(session, "switch-tab", first)
    assert Fixture.background_seen.wait(timeout=5), "inactive tab stopped processing requests"

    before = command(session, "tabs")
    assert command(session, "new-tab", "https://example.invalid/", ok=False) == "OriginNotAllowed"
    assert command(session, "tabs") == before
    for op in ("switch-tab", "close-tab"):
        assert command(session, op, "missing-target", ok=False) == "TabNotFound"
    assert command(session, "eval", "true") is True

    # Discover a tab created outside this CLI. A temporary session must refuse
    # the browser's unrelated default context; a saved-profile session adopts it.
    external = json.loads(browser_request(server, "/json/new?about:blank", "PUT"))["id"]
    if server.ready["persistent_profile"]:
        assert external in {tab["id"] for tab in command(session, "tabs")}
        assert command(session, "switch-tab", external)["id"] == external
        command(session, "content", "<title>External tab</title><p>attached</p>")
        assert command(session, "text", "p") == "attached"
        assert command(session, "close-tab")["closed"] == external
    else:
        assert external not in {tab["id"] for tab in command(session, "tabs")}
        for op in ("switch-tab", "close-tab"):
            assert command(session, op, external, ok=False) == "TabNotFound"
        browser_request(server, "/json/close/" + external)

    command(session, "switch-tab", first)
    assert command(session, "close-tab", second) == {"closed": second, "selected": first}
    assert command(session, "text", "#value") == "first"
    blank = command(session, "new-tab")
    assert blank["url"] == "about:blank" and blank["selected"]
    assert command(session, "close-tab") == {"closed": blank["id"], "selected": first}

    # An external close of the selected tab must recover to its surviving peer.
    doomed = command(session, "new-tab")["id"]
    browser_request(server, "/json/close/" + doomed)
    assert command(session, "status")["tab_id"] == first
    assert command(session, "text", "#value") == "first"

    # Closing the original owning Page must not dispose the shared context.
    replacement = command(session, "close-tab")
    assert replacement["closed"] == first and replacement["selected"] != first
    remaining = command(session, "tabs")
    assert len(remaining) == 1 and remaining[0]["url"] == "about:blank"
    command(session, "open", origin + "/")
    assert command(session, "eval", "localStorage.getItem('tabs-shared')") == "yes"
    assert command(session, "eval", "document.cookie.includes('tabs_shared=yes')") is True
    command(session, "screenshot", str(root / "tabs.png"))
    assert (root / "tabs.png").read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    command(session, "timeout", "30000")


class Fixture(http.server.BaseHTTPRequestHandler):
    background_seen = threading.Event()

    def do_GET(self):
        if self.path == "/background":
            self.background_seen.set()
        body = b'<!doctype html><title>Fixture</title><p id="message">Local page</p>'
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def exercise_agent_commands(server, root):
    def invoke(*args, ok=True, stdin=None):
        result = subprocess.run(
            [EXE, "--session", str(server.path), *args],
            input=stdin, capture_output=True, text=True, timeout=20,
        )
        reply = json.loads(result.stdout)
        assert reply["ok"] is ok, (args, reply, result.stderr)
        assert (result.returncode == 0) is ok
        return reply

    invoke("content", """<!doctype html><title>Agent fixture</title>
      <label>Name<input id="name"></label><textarea aria-label="Notes"></textarea>
      <div contenteditable role="textbox" aria-label="Editor"></div>
      <input type="range" aria-label="Volume">
      <button id="save">Save</button><output id="result"></output>
      <select aria-label="Choice"><option value="a">Alpha</option><option value="b">Beta</option>
      <optgroup disabled><option value="bad">Disabled option</option></optgroup></select>
      <button disabled>Disabled</button><button>Duplicate</button><button>Duplicate</button>
      <input type="file" id="file" hidden><button id="export">Export</button>
      <span id="hidden" hidden>Hidden</span>
      <div style="position:relative;width:100px;height:40px"><button id="covered">Covered</button>
      <div style="position:absolute;inset:0;background:white"></div></div>
      <script>window.trusted=[];document.addEventListener('input',e=>trusted.push(e.isTrusted));
      document.querySelector('#save').onclick=()=>document.querySelector('#result').textContent=document.querySelector('#name').value;
      document.querySelector('#export').onclick=()=>{let a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['agent-download']));a.download='agent.txt';a.click();};</script>""")
    nodes = invoke("snapshot")["result"]["nodes"]
    assert any(n["role"] == "slider" and n["name"] == "Volume" for n in nodes), nodes
    assert any(n["role"] == "textbox" and n["name"] == "Name" for n in nodes)
    clipped = invoke("snapshot", "--limit", "40")["result"]
    assert clipped["truncated"] and clipped["returned_bytes"] <= 40
    invoke("fill", "--role", "textbox", "--name", "Name", "--value", "Sample 🧭")
    invoke("click", "--role", "button", "--name", "Save")
    assert invoke("text", "--selector", "#result")["result"] == "Sample 🧭"
    invoke("click", "--role", "slider", "--name", "Volume")
    assert invoke("eval", "trusted.every(Boolean)")["result"] is True
    secret = "private fixture text\ntrailing newline\n"
    filled = invoke("fill", "--role", "textbox", "--name", "Notes", "--value-file", "-", stdin=secret)
    assert secret not in json.dumps(filled)
    assert invoke("eval", "document.querySelector('textarea').value")["result"] == secret
    value_file = root / "value.txt"
    value_file.write_text("from-file")
    invoke("fill", "--role", "textbox", "--name", "Editor", "--value-file", str(value_file))
    assert invoke("text", "--role", "textbox", "--name", "Editor")["result"] == "from-file"
    invoke("press", "--role", "textbox", "--name", "Editor", "--key", "Control+a")
    invoke("press", "--key", "Backspace")
    assert invoke("eval", "document.querySelector('[contenteditable]').textContent")["result"] == ""
    invoke("select", "--role", "combobox", "--name", "Choice", "--value", "b")
    assert invoke("eval", "document.querySelector('select').value")["result"] == "b"
    assert invoke("select", "--selector", "select", "--value", "bad", ok=False)["err"] == "InvalidSelectOption"
    duplicate = invoke("click", "--role", "button", "--name", "Duplicate", ok=False)
    assert duplicate["err"] == "AmbiguousLocator"
    assert duplicate["error"]["match_count"] == 2 and duplicate["error"]["action"] == "not_started"
    assert invoke("click", "--role", "button", "--name", "Missing", "--timeout", "100", ok=False)["err"] == "ElementNotFound"
    assert invoke("click", "--role", "button", "--name", "Disabled", "--timeout", "100", ok=False)["err"] == "ElementDisabled"
    assert invoke("click", "--selector", "#covered", "--timeout", "100", ok=False)["err"] == "ElementCovered"
    invoke("wait", "--selector", "#hidden", "--state", "hidden")
    invoke("wait", "--selector", "#missing", "--state", "detached")
    invoke("wait", "--selector", "#name", "--state", "visible")
    invoke("wait", "--selector", "#hidden", "--state", "attached")
    script = root / "inspect.js"
    script.write_text("({answer: 42})")
    assert invoke("eval", "--script", str(script))["result"] == {"answer": 42}
    assert invoke("eval", "--script", "-", stdin="6 * 7")["result"] == 42
    result_file = root / "read.json"
    invoke("read", "--limit", "17", "--out", str(result_file))
    saved = json.loads(result_file.read_text())
    assert saved["result"]["truncated"] and saved["result"]["returned_bytes"] <= 17
    assert result_file.stat().st_mode & 0o777 == 0o600
    invoke("upload", "--selector", "#file", str(value_file))
    assert invoke("eval", "document.querySelector('#file').files[0].text()")["result"] == "from-file"
    destination = root / "agent.txt"
    invoke("download", "--role", "button", "--name", "Export", str(destination))
    assert destination.read_text() == "agent-download"
    invoke("content", '<div style="height:3000px">Tall page 🧭</div>')
    document = invoke("eval", "({w:document.documentElement.scrollWidth,h:document.documentElement.scrollHeight})")["result"]
    invoke("screenshot", "--out", str(root / "viewport.png"), "--viewport")
    invoke("screenshot", "--out", str(root / "full.png"), "--full-page")
    viewport = struct.unpack("!II", (root / "viewport.png").read_bytes()[16:24])
    full = struct.unpack("!II", (root / "full.png").read_bytes()[16:24])
    assert viewport == (1280, 720), viewport
    assert full == (document["w"], document["h"]) and full[1] >= 3000, full
    print("Agent inspection, semantic actions, stdin/files, errors and screenshot bounds: passed", flush=True)


def main():
    help_result = subprocess.run([EXE, "--help"], capture_output=True, text=True, check=True)
    assert "--session" in help_result.stdout
    with tempfile.TemporaryDirectory(prefix="zig-cdp-cli-") as directory:
        root = Path(directory)
        session_path = root / "primary"
        with Session(session_path) as server, Session(root / "peer") as peer:
            assert session_path.stat().st_mode & 0o777 == 0o700
            assert command(session_path, "status")["url"] == "about:blank"
            assert command(session_path, "serve", ok=False) == "PathAlreadyExists"
            assert command(session_path, "unknown", ok=False) == "UnknownCommand"
            assert command(session_path, "fill", "#input", ok=False) == "WrongArgumentCount"
            assert command(session_path, "allow", "https://example.invalid/path", ok=False) == "InvalidOrigin"
            assert command(session_path, "allow", "http://user:pass@example.invalid", ok=False) == "InvalidOrigin"
            assert command(session_path, "timeout", "0", ok=False) == "InvalidTimeout"
            assert command(session_path, "open", "https://example.invalid/", ok=False) == "OriginNotAllowed"
            assert raw_request(session_path, b'not json\n')["err"] == "InvalidRequest"
            assert raw_request(session_path, b'{"command":"eval","args":[4]}\n')["err"] == "InvalidRequest"
            assert raw_request(session_path, b'x' * (1024 * 1024 + 1) + b'\n')["err"] == "MessageTooLarge"

            fixture = """<!doctype html><label>Name<input id="name"></label>
                <button id="save">Save</button><p id="result"></p>
                <input type="file" id="file"><button id="export">Export</button>
                <button id="disabled" disabled>Disabled</button>
                <script>
                window.events=[];
                document.querySelector('#name').oninput=e=>events.push(e.isTrusted);
                document.querySelector('#save').onclick=e=>{
                    events.push(e.isTrusted);
                    document.querySelector('#result').textContent=document.querySelector('#name').value;
                };
                document.querySelector('#export').onclick=()=>{
                    const a=document.createElement('a');
                    a.href=URL.createObjectURL(new Blob(['exact,bytes\\r\\n']));
                    a.download='fixture.csv';a.click();
                };
                </script>"""
            command(session_path, "content", fixture)
            text = 'A "quoted" value\nwith Unicode 🧭'
            # HTML text inputs strip line breaks; evaluation still tests JSON escaping.
            assert command(session_path, "eval", json.dumps(text)) == text
            command(session_path, "fill", "#name", "Sample 🧭")
            command(session_path, "click", "#save")
            assert command(session_path, "text", "#result") == "Sample 🧭"
            assert command(session_path, "eval", "events") == [True, True]
            command(session_path, "wait", "document.querySelector('#result').textContent === 'Sample 🧭'")
            assert command(peer.path, "eval", "typeof window.events") == "undefined"

            command(session_path, "screenshot", "shot.png", cwd=root)
            assert (root / "shot.png").read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
            (root / "input.csv").write_bytes(b'header\nvalue\n')
            command(session_path, "upload", "#file", "input.csv", cwd=root)
            assert command(session_path, "eval", "document.querySelector('#file').files[0].text()") == "header\nvalue\n"
            download = command(session_path, "download", "#export", "out.csv", cwd=root)
            assert download["filename"] == "fixture.csv"
            assert download["bytes"] == len(b'exact,bytes\r\n')
            assert (root / "out.csv").read_bytes() == b'exact,bytes\r\n'

            command(session_path, "timeout", "150")
            assert command(session_path, "click", "#disabled", ok=False) == "ElementNotActionable"
            assert command(session_path, "wait", "false", ok=False) == "BrowserConditionTimeout"
            assert command(session_path, "eval", "throw new Error('expected')", ok=False) == "BrowserEvaluationFailed"
            assert command(session_path, "eval", "6*7") == 42
            assert command(session_path, "eval", "'x'.repeat(17*1024*1024)", "--timeout", "5000", ok=False) == "ResponseTooLarge"
            assert command(session_path, "eval", "true") is True
            command(session_path, "timeout", "30000")

            with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as fixture_server:
                thread = threading.Thread(target=fixture_server.serve_forever, daemon=True)
                thread.start()
                try:
                    origin = f"http://127.0.0.1:{fixture_server.server_port}"
                    command(session_path, "allow", origin)
                    assert command(session_path, "open", origin + "/") == origin + "/"
                    assert command(session_path, "text", "#message") == "Local page"
                    command(session_path, "reload")
                    assert command(session_path, "eval", "document.title") == "Fixture"
                    command(session_path, "eval", "setTimeout(() => fetch('/background'), 200); true")
                    assert Fixture.background_seen.wait(timeout=5), "idle session did not process a background request"
                    exercise_tabs(server, origin, root)
                finally:
                    fixture_server.shutdown()
                    thread.join(timeout=5)

            command(session_path, "close")
            server.done()
            assert command(peer.path, "eval", "true") is True
            command(peer.path, "close")
            peer.done()
        print("CLI commands, framing, shared state, isolation, files, errors, and close: passed", flush=True)

        with Session(root / "agent") as server:
            exercise_agent_commands(server, root)
            command(server.path, "close")
            server.done()

        for sig in (signal.SIGINT, signal.SIGTERM):
            with Session(root / f"signal-{sig}") as server:
                # Interrupt while a browser operation is waiting, not just idle accept.
                with subprocess.Popen([EXE, "--session", str(server.path), "wait", "false"], stdout=subprocess.PIPE) as client:
                    time.sleep(0.1)
                    server.process.send_signal(sig)
                    server.done()
                    client.communicate(timeout=5)
                    assert client.returncode != 0
        with Session(root / "idle", "--idle-timeout", "1") as server:
            server.done()
        print("SIGINT, SIGTERM during work, and idle cleanup: passed", flush=True)

        collision = root / "occupied"
        collision.mkdir()
        marker = collision / "keep"
        marker.write_text("unrelated")
        assert command(collision, "serve", ok=False) == "PathAlreadyExists"
        assert marker.read_text() == "unrelated"
        failure = root / "failed-launch"
        assert command(failure, "serve", "--browser", "/no/such/browser", ok=False) == "FileNotFound"
        assert not failure.exists()
        assert command(failure, "serve", "--browser", "/bin/false", ok=False) == "BrowserExited"
        assert not failure.exists()
        print("Existing-directory preservation and launch-failure cleanup: passed", flush=True)

        profile = root / "saved-profile"
        profile.mkdir()
        marker = profile / "keep"
        marker.write_text("caller-owned")
        # These names are caller data too; download staging must be elsewhere.
        (profile / "downloads").mkdir()
        (profile / "downloads" / "keep").write_text("saved download")
        with Session(root / "unrelated") as peer:
            stale_endpoint = (Path(peer.ready["profile"]) / "DevToolsActivePort").read_bytes()
            (profile / "DevToolsActivePort").write_bytes(stale_endpoint)
            for executable, error in (("/no/such/browser", "FileNotFound"), ("/bin/false", "BrowserExited")):
                assert command(failure, "serve", "--user-data-dir", str(profile), "--browser", executable, ok=False) == error
                assert not failure.exists()
                assert marker.read_text() == "caller-owned"
                assert (profile / "DevToolsActivePort").read_bytes() == stale_endpoint
                assert command(peer.path, "eval", "6*7") == 42

            with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as fixture_server:
                thread = threading.Thread(target=fixture_server.serve_forever, daemon=True)
                thread.start()
                origin = f"http://127.0.0.1:{fixture_server.server_port}"
                try:
                    for index in range(2):
                        with Session(root / f"saved-{index}", "--user-data-dir", str(profile), "--allow", origin) as server:
                            assert server.ready["profile"] == str(profile)
                            assert server.ready["persistent_profile"] is True
                            assert server.ready["port"] != peer.ready["port"]
                            assert len(page_targets(server)) == 1, page_targets(server)
                            assert command(failure, "serve", "--user-data-dir", str(profile), ok=False) == "ProfileInUse"
                            assert not failure.exists()
                            assert len(page_targets(server)) == 1
                            command(server.path, "open", origin + "/")
                            if index == 0:
                                exercise_tabs(server, origin, root)
                                command(server.path, "eval", "localStorage.setItem('saved','fixture'); document.cookie='saved=fixture; Max-Age=3600; SameSite=Lax'; true")
                                command(server.path, "eval", "const a=document.createElement('a'); a.id='export'; a.href='data:text/plain,saved-profile-download'; a.download='saved.txt'; a.textContent='Download'; document.body.append(a); true")
                                command(server.path, "download", "#export", str(root / "saved.txt"))
                                assert (root / "saved.txt").read_text() == "saved-profile-download"
                                command(server.path, "close")
                            else:
                                assert command(server.path, "eval", "localStorage.getItem('saved')") == "fixture"
                                assert command(server.path, "eval", "document.cookie.includes('saved=fixture')") is True
                                server.process.send_signal(signal.SIGTERM)
                            server.done()
                            assert marker.read_text() == "caller-owned"
                            assert (profile / "downloads" / "keep").read_text() == "saved download"
                            assert not (profile / "SingletonLock").is_symlink()
                finally:
                    fixture_server.shutdown()
                    thread.join(timeout=5)
            assert command(peer.path, "eval", "true") is True
            command(peer.path, "close")
            peer.done()
        (profile / "SingletonLock").symlink_to("stale-host-12345")
        assert command(failure, "serve", "--user-data-dir", str(profile), ok=False) == "ProfileInUse"
        assert (profile / "SingletonLock").readlink() == Path("stale-host-12345")
        assert not failure.exists()
        assert command(failure, "serve", "--user-data-dir", str(root / "missing-profile"), ok=False) == "FileNotFound"
        assert not failure.exists()
        print("Saved profile cookies/storage, startup tab, busy/stale endpoints, downloads, and preservation: passed", flush=True)


if __name__ == "__main__":
    main()

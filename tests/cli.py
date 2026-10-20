#!/usr/bin/env python3
"""Exercise the installed command interface across independent processes."""
import http.server
import json
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

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
        assert not Path(self.ready["profile"]).exists(), self.ready
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
            assert command(session_path, "eval", "'x'.repeat(17*1024*1024)", ok=False) == "ResponseTooLarge"
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
                finally:
                    fixture_server.shutdown()
                    thread.join(timeout=5)

            command(session_path, "close")
            server.done()
            assert command(peer.path, "eval", "true") is True
            command(peer.path, "close")
            peer.done()
        print("CLI commands, framing, shared state, isolation, files, errors, and close: passed", flush=True)

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


if __name__ == "__main__":
    main()

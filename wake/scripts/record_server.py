"""Local server for capturing real "hey neon" recordings.

Serves scripts/recorder.html over http://localhost and writes uploaded clips
straight into data/my_voice/{positive,negative}/. Serving over localhost (rather
than opening the file directly) matters: getUserMedia only works in a secure
context, and file:// is not one.

Usage:
    python3 scripts/record_server.py [--port 8642]
"""

import argparse
import json
import re
import shutil
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent.parent
PAGE = Path(__file__).resolve().parent / "recorder.html"
VOICE_DIR = ROOT / "data" / "my_voice"
KINDS = ("positive", "negative")
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]+\.wav$")


def kind_dir(qs) -> Path:
    kind = (qs.get("kind") or ["positive"])[0]
    if kind not in KINDS:
        raise ValueError(f"bad kind: {kind}")
    d = VOICE_DIR / kind
    d.mkdir(parents=True, exist_ok=True)
    return d


def safe_clip(d: Path, qs) -> Path:
    name = (qs.get("name") or [""])[0]
    if not SAFE_NAME.match(name):
        raise ValueError(f"bad name: {name}")
    p = (d / name).resolve()
    if p.parent != d.resolve():
        raise ValueError("path escape")
    return p


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        try:
            if u.path in ("/", "/index.html"):
                self._send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
            elif u.path == "/list":
                d = kind_dir(qs)
                self._json({"files": sorted(p.name for p in d.glob("*.wav"))})
            elif u.path == "/clip":
                p = safe_clip(kind_dir(qs), qs)
                self._send(200, p.read_bytes(), "audio/wav")
            else:
                self._send(404, b"{}")
        except Exception as e:
            self._json({"error": str(e)}, 400)

    def do_POST(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        try:
            if u.path == "/upload":
                d = kind_dir(qs)
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                wav = extract_wav(raw)
                stamp = datetime.now(timezone.utc).strftime("%H%M%S_%f")[:-3]
                name = f"{stamp}.wav"
                (d / name).write_bytes(wav)
                n = len(list(d.glob("*.wav")))
                print(f"  saved {qs.get('kind', ['positive'])[0]}/{name}  ({n} total)")
                self._json({"ok": True, "name": name, "count": n})
            elif u.path == "/delete":
                p = safe_clip(kind_dir(qs), qs)
                p.unlink(missing_ok=True)
                self._json({"ok": True})
            else:
                self._send(404, b"{}")
        except Exception as e:
            self._json({"error": str(e)}, 400)

    def log_message(self, *a):
        pass  # keep the console to just the save lines


def extract_wav(body: bytes) -> bytes:
    """Pull the file payload out of a multipart/form-data body.

    The browser sends one part containing a complete WAV, so locating the
    RIFF header and trailing boundary is enough — no need for a full parser.
    """
    start = body.find(b"RIFF")
    if start < 0:
        raise ValueError("no RIFF header in upload")
    end = body.rfind(b"\r\n--", start)
    return body[start:end if end > start else len(body)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8642)
    args = ap.parse_args()

    for k in KINDS:
        (VOICE_DIR / k).mkdir(parents=True, exist_ok=True)

    url = f"http://localhost:{args.port}/"
    counts = {k: len(list((VOICE_DIR / k).glob("*.wav"))) for k in KINDS}
    print(f"\n  hey-neon voice capture")
    print(f"  {url}")
    print(f"  saving to {VOICE_DIR}")
    print(f"  existing: {counts['positive']} positive, {counts['negative']} negative")
    print(f"  ctrl-c to stop\n")

    try:
        ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
    except KeyboardInterrupt:
        final = {k: len(list((VOICE_DIR / k).glob("*.wav"))) for k in KINDS}
        print(f"\n  stopped — {final['positive']} positive, {final['negative']} negative clips\n")


if __name__ == "__main__":
    main()

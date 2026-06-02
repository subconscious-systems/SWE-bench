#!/usr/bin/env python3
"""Logging reverse proxy for capturing LLM request/response traces live.

Sits between mini-swe-agent and the real endpoint; every /v1/chat/completions
call is forwarded verbatim and logged as one JSON line (request body, response
body, status, latency) the moment it completes — so traces are shareable while
the run is still going, and each line can be replayed with curl.

Auth headers are forwarded upstream but NOT written to the trace file.

Usage:
  python3 trace_proxy.py [--port 8788] [--upstream https://api.subconscious.dev]
Trace file: traces/trace-YYYYmmdd-HHMMSS.jsonl  (one line per completed call)

Normally started for you by:  TRACE=1 ./repro.sh
"""
import argparse
import json
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOCK = threading.Lock()


def log_line(path: Path, rec: dict) -> None:
    with LOCK, open(path, "a") as f:
        f.write(json.dumps(rec) + "\n")


def make_handler(upstream: str, trace_file: Path):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # silence default stderr spam
            pass

        def _forward(self, body: bytes | None):
            req = urllib.request.Request(
                upstream + self.path, data=body, method=self.command
            )
            for h in ("Authorization", "Content-Type", "Accept"):
                if self.headers.get(h):
                    req.add_header(h, self.headers[h])
            t0 = time.time()
            status, resp_body, err = 502, b"", None
            try:
                # Generous timeout: runaway generations are exactly what we
                # want to capture, even after the agent client gives up.
                with urllib.request.urlopen(req, timeout=1800) as r:
                    status, resp_body = r.status, r.read()
            except urllib.error.HTTPError as e:
                status, resp_body = e.code, e.read()
            except Exception as e:
                err = str(e)
                resp_body = json.dumps({"proxy_error": err}).encode()
            return status, resp_body, err, time.time() - t0

        def _respond(self, status: int, resp_body: bytes) -> str | None:
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp_body)))
                self.end_headers()
                self.wfile.write(resp_body)
                return None
            except (BrokenPipeError, ConnectionResetError):
                # Client (litellm timeout) hung up before the response came
                # back — still logged below, which is the interesting case.
                return "client_disconnected_before_response"

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b""
            started = datetime.now().isoformat(timespec="milliseconds")
            status, resp_body, err, dt = self._forward(body)
            client_note = self._respond(status, resp_body)
            try:
                req_json = json.loads(body) if body else None
            except ValueError:
                req_json = {"unparsed": body.decode(errors="replace")[:2000]}
            try:
                resp_json = json.loads(resp_body) if resp_body else None
            except ValueError:
                resp_json = {"unparsed": resp_body.decode(errors="replace")[:2000]}
            log_line(
                trace_file,
                {
                    "ts": started,
                    "path": self.path,
                    "latency_s": round(dt, 3),
                    "status": status,
                    "proxy_error": err,
                    "client": client_note,
                    "request": req_json,
                    "response": resp_json,
                },
            )
            usage = (resp_json or {}).get("usage") or {}
            fr = ((resp_json or {}).get("choices") or [{}])[0].get("finish_reason")
            print(
                f"[trace] {started} {dt:7.1f}s status={status} "
                f"finish={fr} completion_tokens={usage.get('completion_tokens')}"
                f"{' ' + client_note if client_note else ''}",
                flush=True,
            )

        def do_GET(self):
            status, resp_body, err, dt = self._forward(None)
            self._respond(status, resp_body)

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--upstream", default="https://api.subconscious.dev")
    args = ap.parse_args()

    trace_dir = Path(__file__).parent / "traces"
    trace_dir.mkdir(exist_ok=True)
    trace_file = trace_dir / f"trace-{datetime.now():%Y%m%d-%H%M%S}.jsonl"
    print(f"[trace] proxy :{args.port} -> {args.upstream}", flush=True)
    print(f"[trace] writing {trace_file}", flush=True)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args.upstream.rstrip("/"), trace_file))
    server.serve_forever()


if __name__ == "__main__":
    main()

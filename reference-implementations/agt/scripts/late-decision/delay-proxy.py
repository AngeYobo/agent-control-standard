#!/usr/bin/env python3
"""Hold one ACS request past the host's decision timeout, then forward it.

Sits between the host and a real, unmodified Guardian. Every request is
forwarded unchanged, except the Nth occurrence of --target-method, which is
held for --delay-seconds BEFORE it reaches the Guardian. The Guardian
therefore evaluates that request, and writes its own response to its envelope
log, only after the host has already given up waiting and settled on its
negotiated failure posture. The Guardian's own timestamps are the evidence of
lateness; this proxy's log records what it held, when, and whether the host
was still listening when the late answer came back.

Every event goes to --log as one JSON line with wall-clock and monotonic time.
"""
import argparse
import json
import socket
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

p = argparse.ArgumentParser()
p.add_argument("--listen-port", type=int, required=True)
p.add_argument("--upstream", required=True, help="Guardian URL, e.g. http://127.0.0.1:8787/acs")
p.add_argument("--target-method", default="steps/toolCallRequest")
p.add_argument("--target-occurrence", type=int, default=2)
p.add_argument("--delay-seconds", type=float, default=8.0)
p.add_argument("--log", required=True)
a = p.parse_args()

lock = threading.Lock()
seen = {}
logf = open(a.log, "a", buffering=1)


def log(event, **fields):
    rec = {"t_wall": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + f".{int(time.time() * 1000) % 1000:03d}Z",
           "t_mono": round(time.monotonic(), 4), "event": event, **fields}
    with lock:
        logf.write(json.dumps(rec) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *unused):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            msg = json.loads(body)
            method, rpc_id = msg.get("method"), msg.get("id")
        except Exception:
            method, rpc_id = None, None
        with lock:
            seen[method] = seen.get(method, 0) + 1
            n = seen[method]
        held = method == a.target_method and n == a.target_occurrence
        log("request_received", method=method, rpc_id=rpc_id, occurrence=n, held=held)
        if held:
            log("hold_start", method=method, rpc_id=rpc_id, delay_seconds=a.delay_seconds)
            time.sleep(a.delay_seconds)
            log("hold_end_forwarding", method=method, rpc_id=rpc_id)
        req = urllib.request.Request(a.upstream, data=body, method="POST",
                                     headers={"Content-Type": self.headers.get("Content-Type", "application/json")})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                status, out = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, out = e.code, e.read()
        decision = None
        try:
            decision = json.loads(out).get("result", {}).get("decision")
        except Exception:
            pass
        log("guardian_responded", method=method, rpc_id=rpc_id, status=status, decision=decision, held=held)
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            self.wfile.flush()
            # A closed peer is often only visible on a second write or a read.
            self.connection.setblocking(False)
            try:
                peer_closed = self.connection.recv(1, socket.MSG_PEEK) == b""
            except BlockingIOError:
                peer_closed = False
            except OSError:
                peer_closed = True
            log("response_written", method=method, rpc_id=rpc_id, held=held, peer_closed=peer_closed)
        except OSError as e:
            log("client_gone", method=method, rpc_id=rpc_id, held=held, error=type(e).__name__)


log("proxy_start", listen_port=a.listen_port, upstream=a.upstream, target_method=a.target_method,
    target_occurrence=a.target_occurrence, delay_seconds=a.delay_seconds)
ThreadingHTTPServer(("127.0.0.1", a.listen_port), Handler).serve_forever()

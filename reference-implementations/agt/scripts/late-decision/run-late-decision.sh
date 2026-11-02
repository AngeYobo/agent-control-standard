#!/usr/bin/env bash
# Late-decision run (re-run of the 16 Sep "Phase 4F-v2" trial).
# Real OpenCode, real host adapter, real unmodified Guardian. One request -- the
# second steps/toolCallRequest, the destructive command the Guardian denies --
# is held by delay-proxy.py past the 5 s negotiated timeout before it reaches
# the Guardian. Expected: the host times out, proceeds under the negotiated
# posture, runs the command; the Guardian's DENY is written afterwards.
#
# Everything lands in ~/acs-evidence/, never /tmp. Nothing is pushed.
set -euo pipefail

REPO="${REPO:-$HOME/agent-control-standard}"
AGT="$REPO/reference-implementations/agt"
HERE="$(cd "$(dirname "$0")" && pwd)"
DELAY="${DELAY:-8}"
# The pinned AGT native binding needs glibc >= 2.39; Ubuntu 22.04 has 2.35.
# "docker" runs only the Guardian in ubuntu:24.04, with the repository mounted
# read-only (same node_modules, same binary) and the host's own bun binary.
GUARDIAN_RUNTIME="${GUARDIAN_RUNTIME:-docker}"
GUARDIAN_IMAGE="${GUARDIAN_IMAGE:-ubuntu:24.04}"
CNAME="acs-late-guardian-$$"
EVID="$HOME/acs-evidence/late-decision-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EVID"
echo "evidence: $EVID"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
GP=$(free_port); PP=$(free_port)

# ── provenance ────────────────────────────────────────────────────────────────
{
  echo "date_utc: $(date -u +%FT%TZ)"
  echo "acs_head: $(git -C "$REPO" rev-parse HEAD)"
  echo "acs_branch: $(git -C "$REPO" branch --show-current)"
  echo "fixture_base: ea1e3459c7a43d354bfd0f84391dee044b7a581f"
  echo "worktree_dirty: $(git -C "$REPO" status --porcelain | wc -l) path(s)"
  echo "bun: $(bun --version)"
  echo "opencode: $(opencode --version)"
  echo "python: $(python3 --version 2>&1)"
  echo "kernel: $(uname -sr)"
  echo "delay_seconds: $DELAY"
  echo "host_glibc: $(ldd --version | head -1)"
  echo "guardian_runtime: $GUARDIAN_RUNTIME"
  if [[ "$GUARDIAN_RUNTIME" == docker ]]; then
    echo "guardian_image: $GUARDIAN_IMAGE $(docker image inspect "$GUARDIAN_IMAGE" --format '{{.Id}}')"
    echo "guardian_glibc: $(docker run --rm "$GUARDIAN_IMAGE" ldd --version | head -1)"
  fi
  echo "guardian_port: $GP"
  echo "proxy_port: $PP"
} > "$EVID/provenance.txt"
git -C "$REPO" diff ea1e3459c7a43d354bfd0f84391dee044b7a581f -- reference-implementations/agt/scripts/dogfood-opencode.py > "$EVID/fixture-vs-ea1e345.diff"
cp "$HERE/delay-proxy.py" "$HERE/run-late-decision.sh" "$EVID/"

# ── Guardian (unmodified), then proxy ─────────────────────────────────────────
cleanup() {
  [[ -n "${PXPID:-}" ]] && kill "$PXPID" 2>/dev/null || true
  if [[ "$GUARDIAN_RUNTIME" == docker ]]; then docker stop -t 2 "$CNAME" >/dev/null 2>&1 || true; fi
  [[ -n "${GPID:-}" ]] && kill "$GPID" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$GUARDIAN_RUNTIME" == docker ]]; then
  docker run --rm --name "$CNAME" --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$(command -v bun):/usr/local/bin/bun:ro" \
    -v "$REPO:$REPO:ro" -v "$EVID:$EVID" -w "$AGT" \
    -e ACS_GUARDIAN_PORT="$GP" -e ACS_GUARDIAN_HOST=127.0.0.1 \
    -e ACS_ON_DECISION_FAILURE=proceed \
    -e ACS_ENVELOPE_LOG="$EVID/guardian-envelopes.jsonl" \
    -e ACS_SESSION_CONTEXT_LOG="$EVID/guardian-context.jsonl" \
    "$GUARDIAN_IMAGE" bun run packages/guardian/src/main.ts > "$EVID/guardian.log" 2>&1 &
else
  ( cd "$AGT" && ACS_GUARDIAN_PORT="$GP" ACS_GUARDIAN_HOST=127.0.0.1 \
      ACS_ON_DECISION_FAILURE=proceed \
      ACS_ENVELOPE_LOG="$EVID/guardian-envelopes.jsonl" \
      ACS_SESSION_CONTEXT_LOG="$EVID/guardian-context.jsonl" \
      exec bun run packages/guardian/src/main.ts ) > "$EVID/guardian.log" 2>&1 &
fi
GPID=$!
for _ in $(seq 150); do grep -q "Guardian listening" "$EVID/guardian.log" 2>/dev/null && break; sleep 0.1; done
grep -q "Guardian listening" "$EVID/guardian.log" || { echo "Guardian did not start"; cat "$EVID/guardian.log"; exit 1; }

python3 "$HERE/delay-proxy.py" --listen-port "$PP" --upstream "http://127.0.0.1:$GP/acs" \
  --delay-seconds "$DELAY" --log "$EVID/proxy.jsonl" > "$EVID/proxy.stderr" 2>&1 &
PXPID=$!
sleep 0.5

# ── host run through the proxy ────────────────────────────────────────────────
set +e
ACS_TEST_GUARDIAN_URL="http://127.0.0.1:$PP/acs" \
ACS_TEST_ENVELOPE_LOG="$EVID/guardian-envelopes.jsonl" \
  python3 "$AGT/scripts/dogfood-opencode.py" live --output "$EVID/run" > "$EVID/fixture.out" 2>&1
echo "fixture_exit: $?" >> "$EVID/provenance.txt"
set -e

# ── wait for the held request's late answer, then stop everything ─────────────
for _ in $(seq 300); do grep -q '"guardian_responded".*"held": true' "$EVID/proxy.jsonl" 2>/dev/null && break; sleep 0.1; done
sleep 1
cleanup; trap - EXIT

# ── result ───────────────────────────────────────────────────────────────────
python3 - "$EVID" <<'PY' | tee "$EVID/RESULT.txt"
import json, sys, pathlib
e = pathlib.Path(sys.argv[1]); run = e / "run"
rows = lambda p: [json.loads(l) for l in p.read_text().splitlines() if l.strip()] if p.exists() else []
proxy, guard, audit = rows(e/"proxy.jsonl"), rows(e/"guardian-envelopes.jsonl"), rows(run/"audit.jsonl")
held = [r for r in proxy if r.get("held") and r["event"] == "request_received"]
if not held:
    print("NO HELD REQUEST -- the run did not reach the second tool call"); sys.exit()
rid = held[0]["rpc_id"]
print(f"held rpc_id: {rid}")
print("\n-- proxy (held request)")
for r in proxy:
    if r.get("rpc_id") == rid: print(f"  {r['t_wall']}  {r['event']}" + (f"  decision={r['decision']}" if r.get('decision') else "") + (f"  peer_closed={r['peer_closed']}" if 'peer_closed' in r else ""))
print("\n-- guardian envelope log (held rpc_id)")
for r in guard:
    if r.get("rpc_id") == rid:
        d = (r.get("envelope") or {}).get("result", {}).get("decision") if r["direction"] == "response" else ""
        print(f"  {r['recorded_at']}  {r['direction']:<8} {r['method']}  {d or ''}")
print("\n-- host failure audit")
for r in audit:
    print("  " + json.dumps({k: r.get(k) for k in ("method", "rpc_id", "outcome", "posture", "posture_source")} | {"failure": r.get("failure")}))
host = rows(run/"host.jsonl")
tools = [ev["part"] for ev in host if ev.get("type") == "tool_use"]
print("\n-- host tool outcomes")
for t in tools: print(f"  {t['state']['status']:<10} {t['state']['input'].get('command')}")
dt = run / "denied.txt"
print(f"\n-- effect marker denied.txt: {'PRESENT: ' + dt.read_text().strip() if dt.exists() else 'absent'}")
import datetime as _dt
def _ts(x):
    x = x.strip().replace("Z", "")
    head, _, frac = x.partition(".")
    return _dt.datetime.fromisoformat(head + "." + (frac + "000000")[:6]).replace(tzinfo=_dt.timezone.utc)
stamps = {n: (run / n).read_text().strip() for n in ("dispatched.txt", "finished.txt") if (run / n).exists()}
print("\n-- command self-timestamps (host clock, UTC)")
for n, v in stamps.items(): print(f"  {n:<15} {v}")
fallback = next((r["recorded_at"] for r in audit if r.get("rpc_id") == rid), None)
deny = next((r["recorded_at"] for r in guard if r.get("rpc_id") == rid and r["direction"] == "response"), None)
if "dispatched.txt" in stamps and fallback and deny:
    d = _ts(stamps["dispatched.txt"])
    print(f"  dispatch - host fallback   : {(d - _ts(fallback)).total_seconds()*1000:+.3f} ms")
    if "finished.txt" in stamps: print(f"  finished - dispatch        : {(_ts(stamps['finished.txt']) - d).total_seconds()*1000:+.3f} ms")
    print(f"  guardian deny - dispatch   : {(_ts(deny) - d).total_seconds()*1000:+.3f} ms")
print("\n-- fixture said:")
print("  " + (e/"fixture.out").read_text().strip().splitlines()[-1] if (e/"fixture.out").exists() and (e/"fixture.out").read_text().strip() else "  (nothing)")
PY

( cd "$EVID" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
echo "done: $EVID"

#!/usr/bin/env python3
"""Same-machine A/B benchmark of an isolated CrossPet build: startup, idle and busy CPU/RSS, event->render latency.

usage: bench.py <CrossPet.app> <families|clients> <label> <out.json> [idle_seconds] [busy_seconds]
The harness drives the repo hook script with synthetic events (CROSSPET_CLIENT labels them for the 3-family baseline),
so numbers compare builds, they are not a real-client measurement.
"""
import json, os, re, shutil, statistics, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "integrations/crosspet-hook.py"
app, mode, label, out = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
IDLE = int(sys.argv[5]) if len(sys.argv) > 5 else 120
BUSY = int(sys.argv[6]) if len(sys.argv) > 6 else 60
tmp = Path(tempfile.mkdtemp(prefix="crosspet-bench."))
for d in ("home", "data", "state"):
    (tmp / d).mkdir()
(tmp / "data/ai-autostart-off").touch()
suite = f"io.github.crosspet.test.bench.{os.getpid()}"
subprocess.run(["defaults", "write", suite, "petMode", "-string", mode], check=True)
trace = tmp / "trace.jsonl"
env = dict(os.environ, CFFIXED_USER_HOME=str(tmp / "home"), CROSSPET_PREFERENCES_SUITE=suite, CROSSPET_DATA_DIR=str(tmp / "data"),
           CROSSPET_STATE_DIR=str(tmp / "state"), CROSSPET_RENDER_TRACE=str(trace))
for k in ("CROSSPET_CLIENT", "CLAUDE_CODE_ENTRYPOINT"):
    env.pop(k, None)
pets = {"families": 3, "clients": 5}[mode]


def webkit_pids():
    text = subprocess.run(["ps", "-ax", "-o", "pid=,command="], capture_output=True, text=True).stdout
    return {int(l.split()[0]) for l in text.splitlines() if re.search(r"com\.apple\.WebKit\.(WebContent|Networking|GPU)", l)}


def cpu_seconds(pids):
    total = 0.0
    for l in subprocess.run(["ps", "-o", "time=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout.split():
        parts = l.replace(",", ".").split(":")
        total += sum(float(x) * 60 ** i for i, x in enumerate(reversed(parts)))
    return total


def rss_mb(pids):
    return sum(int(x) for x in subprocess.run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout.split()) / 1024


def send(host, event, sid, client):
    payload = json.dumps(dict(hook_event_name=event, session_id=sid, cwd="/tmp", tool_name="Read"))
    e = dict(env, CROSSPET_CLIENT=client)
    subprocess.run([sys.executable, str(HOOK), host], input=payload, text=True, capture_output=True, env=e, timeout=15)


WINCOUNT = Path(tempfile.gettempdir()) / "crosspet-wincount"
if not WINCOUNT.exists():
    subprocess.run(["swiftc", "-O", str(ROOT / "tests/wincount.swift"), "-o", str(WINCOUNT)], check=True)


def windows_visible(pid):
    return int(subprocess.run([str(WINCOUNT), str(pid)], capture_output=True, text=True).stdout.strip() or 0)


hosts = [("claude", "tui"), ("claude", "desktop"), ("gpt", "tui"), ("gpt", "desktop"), ("deepseek", "desktop")] if mode == "clients" \
    else [("claude", "tui"), ("gpt", "tui"), ("deepseek", "desktop")]
proc = None
result = {"label": label, "mode": mode, "app": str(app), "pets": pets, "machine": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()}
try:
    before = webkit_pids()
    t0 = time.time()
    proc = subprocess.Popen([str(app / "Contents/MacOS/CrossPet")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # startup: wall time from exec until every pet window exists
    while time.time() - t0 < 30 and windows_visible(proc.pid) < pets:
        time.sleep(0.05)
    result["startup_windows_s"] = round(time.time() - t0, 2)
    time.sleep(8)
    wk = webkit_pids() - before
    procs = [proc.pid] + sorted(wk)
    result["webkit_processes"] = len(wk)
    # idle phase: no events; the page rests (effects stop after 30 s), so let that settle first
    time.sleep(35)
    c0, w0 = cpu_seconds([proc.pid]), cpu_seconds(sorted(wk)); t = time.time()
    time.sleep(IDLE)
    c1, w1 = cpu_seconds([proc.pid]), cpu_seconds(sorted(wk)); dt = time.time() - t
    result["idle"] = {"seconds": round(dt), "main_cpu_pct": round(100 * (c1 - c0) / dt, 2), "webkit_cpu_pct": round(100 * (w1 - w0) / dt, 2),
                      "main_rss_mb": round(rss_mb([proc.pid]), 1), "webkit_rss_mb": round(rss_mb(sorted(wk)), 1)}
    # busy phase: every pet gets a tool event every 4 s (keeps the work animation running)
    c0, w0 = cpu_seconds([proc.pid]), cpu_seconds(sorted(wk)); t = time.time(); n = 0
    while time.time() - t < BUSY:
        for host, client in hosts:
            send(host, "PreToolUse" if n % 2 == 0 else "UserPromptSubmit", f"bench-{host}-{client}", client)
        n += 1
        time.sleep(max(0, 4 - 0.4 * len(hosts)))
    c1, w1 = cpu_seconds([proc.pid]), cpu_seconds(sorted(wk)); dt = time.time() - t
    result["busy"] = {"seconds": round(dt), "main_cpu_pct": round(100 * (c1 - c0) / dt, 2), "webkit_cpu_pct": round(100 * (w1 - w0) / dt, 2),
                      "main_rss_mb": round(rss_mb([proc.pid]), 1), "webkit_rss_mb": round(rss_mb(sorted(wk)), 1)}
    # latency: event timestamp (hook receipt) -> badge rendered, from the opt-in render trace
    lat = []
    if trace.exists():
        for line in trace.read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if "displayAt" in r and r.get("ts") and r.get("event") not in ("NoSessions",) and "kind" not in r:
                lat.append(r["displayAt"] - r["ts"])
    if lat:
        result["event_to_render_ms"] = {"n": len(lat), "median": round(statistics.median(lat) * 1000), "p90": round(sorted(lat)[int(len(lat) * 0.9) - 1] * 1000), "max": round(max(lat) * 1000)}
    result["bundle_mb"] = round(sum(f.stat().st_size for f in app.rglob("*") if f.is_file()) / 1e6, 1)
    result["binary_kb"] = round((app / "Contents/MacOS/CrossPet").stat().st_size / 1024)
    proc.terminate(); proc.wait()
finally:
    if proc is not None and proc.poll() is None:
        proc.terminate(); proc.wait(timeout=10)
    for domain in [suite] + [suite + ".pet." + pet for pet in ["claude", "gpt", "deepseek", "claude-tui", "claude-desktop", "codex-tui", "codex-desktop", "dsh-desktop"]]:
        subprocess.run(["defaults", "delete", domain], capture_output=True)
    shutil.rmtree(tmp, ignore_errors=True)
out.write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))

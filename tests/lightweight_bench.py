#!/usr/bin/env python3
"""Isolated lightweight A/B: two enabled pets, 50 unchanged foreign/unknown snapshots.

Usage: lightweight_bench.py <CrossPet.app> <label> <out.json> [idle_s=60] [busy_s=30]
Uses macOS's read-only responsibility_get_pid_responsible_for_pid query to attribute
WebKit CPU/RSS to this exact App. Synthetic hook events are not real-client E2E.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PETS = ['claude-tui', 'claude-desktop', 'codex-tui', 'codex-desktop', 'dsh-desktop']
FAMILIES = ['claude', 'gpt', 'deepseek']
ENABLED = ['claude-tui', 'codex-desktop']
SWIFT_WINDOWS = r'''
import Cocoa
if CommandLine.arguments[1] == "launch" {
    let app = URL(fileURLWithPath: CommandLine.arguments[2])
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let env = try! JSONSerialization.jsonObject(with: data) as! [String: String]
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false; config.createsNewApplicationInstance = true; config.environment = env
    NSWorkspace.shared.openApplication(at: app, configuration: config) { process, error in
        guard let process else { fputs("launch failed: \(error?.localizedDescription ?? "unknown")\n", stderr); exit(2) }
        print(process.processIdentifier); fflush(stdout); exit(0)
    }
    RunLoop.main.run(); exit(2)
}
let pid = Int32(CommandLine.arguments[1])!
let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
let rows: [[String: Any]] = windows.map { ["alpha": $0[kCGWindowAlpha as String] ?? -1,
    "onscreen": $0[kCGWindowIsOnscreen as String] ?? false, "bounds": $0[kCGWindowBounds as String] ?? [:]] }
print(String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
'''


def run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, check=True, **kwargs)


def main():
    app = Path(sys.argv[1]).resolve()
    label, output = sys.argv[2], Path(sys.argv[3]).resolve()
    idle_s = int(sys.argv[4]) if len(sys.argv) > 4 else 60
    busy_s = int(sys.argv[5]) if len(sys.argv) > 5 else 30
    binary = app / 'Contents/MacOS/CrossPet'
    scratch = Path(tempfile.mkdtemp(prefix='crosspet-lightweight-bench.')).resolve()
    suite = f'io.github.crosspet.test.lightweight.{os.getpid()}'
    for name in ['home', 'data', 'state']:
        (scratch / name).mkdir()
    (scratch / 'data/ai-autostart-off').touch()
    (scratch / 'windows.swift').write_text(SWIFT_WINDOWS)
    run(['swiftc', '-O', str(scratch / 'windows.swift'), '-o', str(scratch / 'windows')])
    trace = scratch / 'trace.jsonl'
    env = dict(os.environ, CFFIXED_USER_HOME=str(scratch / 'home'), CROSSPET_DATA_DIR=str(scratch / 'data'),
               CROSSPET_STATE_DIR=str(scratch / 'state'), CROSSPET_PREFERENCES_SUITE=suite,
               CROSSPET_RENDER_TRACE=str(trace))
    for key in ['CROSSPET_CLIENT', 'CLAUDE_CODE_ENTRYPOINT', 'CROSSPET_PROBE_MODE', 'CROSSPET_PROBE_OUTPUT']:
        env.pop(key, None)
    lib = ctypes.CDLL(None)
    try:
        responsible = lib.responsibility_get_pid_responsible_for_pid
    except AttributeError:
        shutil.rmtree(scratch)
        raise SystemExit('Responsible-PID query unavailable; refusing to attribute system-wide WebKit to this App.')
    responsible.argtypes = [ctypes.c_int]
    responsible.restype = ctypes.c_int

    def default(domain, key, kind, value):
        run(['/usr/bin/defaults', 'write', domain, key, kind, str(value)])

    default(suite, 'petMode', '-string', 'clients')
    default(suite, 'hideFullscreen', '-bool', 'false')
    default(suite, 'appearanceEnabled', '-bool', 'false')
    for i, pet in enumerate(PETS):
        domain = suite + '.pet.' + pet
        for key, kind, value in [('familySchema', '-int', 1), ('enabled', '-bool', str(pet in ENABLED).lower()),
                                 ('hideFullscreen', '-bool', 'false'), ('edgeDock', '-bool', 'false'),
                                 ('powerSave', '-bool', 'false'), ('size', '-float', .8),
                                 ('gptQuota', '-bool', 'false'), ('agyQuota', '-bool', 'false'),
                                 ('dsQuota', '-bool', 'false'), ('appearanceMode', '-string', 'onWork')]:
            default(domain, key, kind, value)
        run(['/usr/bin/defaults', 'write', domain, 'origin', '-array', str(60 + i * 230), '140'])
    # Same 50 stable files in both runs; none can be routed to either enabled pet.
    now = time.time()
    for i in range(50):
        family, source, other = ('claude', 'claude-code', 'desktop') if i < 30 else ('gpt', 'codex', 'tui')
        folder = scratch / 'state/families' / family
        folder.mkdir(parents=True, exist_ok=True)
        snapshot = dict(schema=1, family=family, source=source, client=other if i % 2 else 'unknown',
                        sessionId=f'historical-fixture-{i}', model='benchmark', status='Thinking', pose='thinking',
                        event='PostToolUse', ts=now - 3600, observedAt=now - 3600,
                        sequence=1, producerId='benchmark-history')
        (folder / f'fixture-{i}.json').write_text(json.dumps(snapshot))

    def table():
        rows = {}
        text = run(['/bin/ps', '-A', '-o', 'pid=,time=,rss=,comm=']).stdout
        for line in text.splitlines():
            fields = line.split(None, 3)
            if len(fields) != 4:
                continue
            pid, cpu, rss, command = fields
            seconds = 0.0
            for part in cpu.replace(',', '.').split(':'):
                seconds = seconds * 60 + float(part)
            rows[int(pid)] = dict(cpu_seconds=seconds, rss_mb=int(rss) / 1024, executable=command)
        return rows

    class OwnedApp:
        def __init__(self, pid):
            self.pid = pid
            self.returncode = None

        def poll(self):
            text = subprocess.run(['/bin/ps', '-p', str(self.pid), '-o', 'stat=,comm='], capture_output=True, text=True).stdout.strip()
            fields = text.split(None, 1)
            if len(fields) != 2 or fields[0].startswith('Z') or Path(fields[1]).resolve() != binary.resolve():
                self.returncode = 0
            return self.returncode

        def terminate(self):
            if self.poll() is None:
                os.kill(self.pid, signal.SIGTERM)

        def kill(self):
            if self.poll() is None:
                os.kill(self.pid, signal.SIGKILL)

        def wait(self, timeout):
            end = time.monotonic() + timeout
            while self.poll() is None and time.monotonic() < end:
                time.sleep(.1)
            if self.poll() is None:
                raise subprocess.TimeoutExpired(str(binary), timeout)
            return self.returncode

    proc = None
    result = dict(label=label, app=str(app), binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  machine=run(['sysctl', '-n', 'machdep.cpu.brand_string']).stdout.strip(),
                  enabledPets=ENABLED, disabledPets=[p for p in PETS if p not in ENABLED], fixtureFiles=50,
                  attribution='libSystem responsibility_get_pid_responsible_for_pid(pid) == exact isolated App PID',
                  limitations=['Single sequential A/B pair; cache and system workload can vary.',
                               'CPU percentage uses one-core 100%; RSS is not physical footprint.',
                               'Synthetic historical files and hook events, not real client tasks.',
                               'CGWindowList may omit windows not registered with WindowServer.'])
    try:
        started = time.monotonic()
        launch_env = {key: value for key, value in env.items() if key.startswith('CROSSPET_') or key == 'CFFIXED_USER_HOME'}
        launch_env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
        (scratch / 'launch-env.json').write_text(json.dumps(launch_env))
        pid = int(run([str(scratch / 'windows'), 'launch', str(app), str(scratch / 'launch-env.json')], timeout=20).stdout.strip())
        proc = OwnedApp(pid)
        result['appPID'] = pid
        result['appResponsiblePID'] = responsible(pid)
        if result['appResponsiblePID'] != pid:
            raise RuntimeError('Independent App launch did not obtain its own responsibility PID')

        def windows():
            return json.loads(run([str(scratch / 'windows'), str(proc.pid)]).stdout)

        def attributed():
            data = table()
            return {pid: row for pid, row in data.items() if pid == proc.pid or
                    ('com.apple.WebKit.' in row['executable'] and responsible(pid) == proc.pid)}

        while time.monotonic() - started < 30:
            current = windows()
            if len([w for w in current if w['onscreen'] and w['alpha'] > .5]) == 2:
                break
            if proc.poll() is not None:
                raise RuntimeError(f'isolated App exited {proc.returncode}')
            time.sleep(.1)
        else:
            raise RuntimeError('Two visible enabled pet windows did not appear within 30 seconds')
        result['startup_visible_windows_s'] = round(time.monotonic() - started, 3)
        time.sleep(8)
        result['startupWindows'] = windows()
        initial = attributed()
        result['startupProcesses'] = {str(pid): row for pid, row in initial.items()}
        result['startup_webContent_processes'] = sum('com.apple.WebKit.WebContent' in row['executable'] for row in initial.values())
        result['startup_webkit_processes'] = len(initial) - 1
        if result['startup_webContent_processes'] < 2:
            raise RuntimeError('Expected at least two attributed WebContent processes; refusing zero-attribution metrics')
        print(f'{label}: windows={len(result["startupWindows"])} webContent={result["startup_webContent_processes"]}; warming 35 seconds', flush=True)
        time.sleep(35)

        def phase(name, seconds, busy=False):
            before, begin = attributed(), time.monotonic()
            n = 0
            while time.monotonic() - begin < seconds:
                if busy:
                    for family, client, sid in [('claude', 'tui', 'bench-claude'), ('gpt', 'desktop', 'bench-codex')]:
                        event = 'PreToolUse' if n % 2 else 'UserPromptSubmit'
                        payload = json.dumps(dict(hook_event_name=event, session_id=sid, cwd='/tmp', tool_name='Read'))
                        run([sys.executable, str(ROOT / 'integrations/crosspet-hook.py'), family], input=payload,
                            env=dict(env, CROSSPET_CLIENT=client), timeout=15)
                    n += 1
                    time.sleep(min(3.8, max(0, seconds - (time.monotonic() - begin))))
                else:
                    time.sleep(min(1, max(0, seconds - (time.monotonic() - begin))))
                if proc.poll() is not None:
                    raise RuntimeError(f'isolated App exited during {name}')
            after, duration = attributed(), time.monotonic() - begin
            exited = sorted(set(before) - set(after))
            added = sorted(set(after) - set(before))
            main_cpu = (after[proc.pid]['cpu_seconds'] - before[proc.pid]['cpu_seconds']) / duration * 100
            wk_delta = sum(row['cpu_seconds'] - before.get(pid, {}).get('cpu_seconds', 0)
                           for pid, row in after.items() if pid != proc.pid)
            stats = dict(seconds=round(duration, 2), main_cpu_pct=round(main_cpu, 3),
                         webkit_cpu_pct=round(wk_delta / duration * 100, 3),
                         main_rss_mb=round(after[proc.pid]['rss_mb'], 1),
                         webkit_rss_mb=round(sum(r['rss_mb'] for pid, r in after.items() if pid != proc.pid), 1),
                         webContent_processes=sum('com.apple.WebKit.WebContent' in r['executable'] for r in after.values()),
                         webkit_processes=len(after) - 1, exitedPIDs=exited, addedPIDs=added,
                         cpuComplete=not exited, processes={str(pid): row for pid, row in after.items()})
            result[name] = stats
            print(name, json.dumps({k: v for k, v in stats.items() if k != 'processes'}), flush=True)

        phase('idle', idle_s)
        phase('busy', busy_s, busy=True)
        latencies = []
        if trace.exists():
            for line in trace.read_text().splitlines():
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if row.get('event') in ['PreToolUse', 'UserPromptSubmit'] and row.get('displayAt') and row.get('ts') and not row.get('kind'):
                    latency = (row['displayAt'] - row['ts']) * 1000
                    if 0 <= latency < 10000:
                        latencies.append(latency)
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(trace, output.with_suffix('.trace.jsonl'))
        if latencies:
            result['event_to_render_ms'] = dict(n=len(latencies), median=round(statistics.median(latencies)),
                                               p90=round(sorted(latencies)[max(0, int(len(latencies) * .9) - 1)]), max=round(max(latencies)))
        result['completed'] = True
    except BaseException as exc:
        result.update(completed=False, error=repr(exc))
        raise
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait(timeout=5)
        for domain in [suite] + [suite + '.pet.' + pet for pet in PETS + FAMILIES]:
            subprocess.run(['/usr/bin/defaults', 'delete', domain], capture_output=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2))
        shutil.rmtree(scratch)
    print(json.dumps({k: v for k, v in result.items() if k not in ['startupProcesses', 'startupWindows']}, indent=2), flush=True)


if __name__ == '__main__':
    main()

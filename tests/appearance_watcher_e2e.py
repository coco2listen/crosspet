#!/usr/bin/env python3
"""Real watcher/main processes with a synthetic host, never real client control.

Usage: appearance_watcher_e2e.py <CrossPet.app> <evidence.json>
No production LaunchAgent is installed. The user's running clients are untouched.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PETS = ['claude-tui', 'claude-desktop', 'codex-tui', 'codex-desktop', 'dsh-desktop']
FAMILIES = ['claude', 'gpt', 'deepseek']


def main():
    source, evidence = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    scratch = Path(tempfile.mkdtemp(prefix='crosspet-appearance-e2e.')).resolve()
    suite = f'io.github.crosspet.test.appearance.e2e.{os.getpid()}'
    app = scratch / 'CrossPet.app'
    shutil.copytree(source, app, symlinks=True)
    binary = app / 'Contents/MacOS/CrossPet'
    for folder in ['home', 'data', 'state']:
        (scratch / folder).mkdir()
    data, state = scratch / 'data', scratch / 'state'
    (data / 'ai-autostart-off').touch()
    env = dict(os.environ, CFFIXED_USER_HOME=str(scratch / 'home'),
               CROSSPET_DATA_DIR=str(data), CROSSPET_STATE_DIR=str(state),
               CROSSPET_PREFERENCES_SUITE=suite)
    for key in ['CROSSPET_PROBE_OUTPUT', 'CROSSPET_PROBE_MODE', 'CROSSPET_RENDER_TRACE']:
        env.pop(key, None)
    log = (scratch / 'process.log').open('w')
    watcher, host = None, None
    owned_mains, results, failure_snapshot = set(), [], {}
    stub = scratch / 'host/Claude.app/Contents/MacOS/Claude'
    stub.parent.mkdir(parents=True)
    subprocess.run(['/usr/bin/clang', '-x', 'c', '-', '-o', str(stub)],
                   input='#include <unistd.h>\nint main(void) { sleep(240); return 0; }\n',
                   text=True, capture_output=True, check=True)

    def check(name, passed, detail=''):
        results.append(dict(name=name, passed=bool(passed), detail=str(detail)))
        print(('PASS' if passed else 'FAIL'), name, detail, flush=True)
        if not passed:
            failure_snapshot.update(configuration=json.loads((data / 'appearance.json').read_text()) if (data / 'appearance.json').exists() else None,
                                    quitAt=(data / 'user-quit').stat().st_mtime if (data / 'user-quit').exists() else None,
                                    pidFile=(state / 'pet.pid').read_text() if (state / 'pet.pid').exists() else None,
                                    watcherStatus=watcher.poll() if watcher else None,
                                    hostStatus=host.poll() if host else None,
                                    ownedProcessTable=subprocess.run(['/bin/ps', '-p', ','.join(str(pid) for pid in owned_mains | {watcher.pid if watcher else 0, host.pid if host else 0}), '-o', 'pid=,ppid=,lstart=,comm='], capture_output=True, text=True).stdout)
            raise AssertionError(name)

    def defaults(domain, key, kind, value):
        subprocess.run(['/usr/bin/defaults', 'write', domain, key, kind, str(value)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)

    def pid_alive(pid):
        if not pid:
            return False
        comm = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'comm='], text=True,
                              capture_output=True).stdout.strip()
        return bool(comm) and Path(comm).resolve() == binary.resolve()

    def main_pid():
        try:
            pid = int((state / 'pet.pid').read_text().strip())
        except (OSError, ValueError):
            return None
        if pid_alive(pid):
            owned_mains.add(pid)
            return pid
        return None

    def wait_main(seconds=18):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            pid = main_pid()
            if pid:
                return pid
            time.sleep(.2)
        return None

    def stop_main():
        pid = main_pid()
        if pid:
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 5
            while pid_alive(pid) and time.monotonic() < deadline:
                time.sleep(.1)
            if pid_alive(pid):
                os.kill(pid, signal.SIGKILL)
        (state / 'pet.pid').unlink(missing_ok=True)

    def stop_child(child):
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)

    def configure(mode='followApp', enabled=True, master=True, quit=False):
        defaults(suite, 'petMode', '-string', 'clients')
        defaults(suite, 'appearanceEnabled', '-bool', str(master).lower())
        for pet in PETS:
            domain = suite + '.pet.' + pet
            defaults(domain, 'enabled', '-bool', str(enabled and pet == 'claude-desktop').lower())
            defaults(domain, 'appearanceMode', '-string', mode if pet == 'claude-desktop' else 'onWork')
        config = dict(master=master, pets=[dict(id='claude-desktop', mode=mode, enabled=enabled)])
        temporary = data / 'appearance.json.tmp'
        temporary.write_text(json.dumps(config))
        temporary.replace(data / 'appearance.json')
        (data / 'user-quit').unlink(missing_ok=True)
        if quit:
            (data / 'user-quit').touch()

    def start_watcher():
        return subprocess.Popen([str(binary), '--appearance-watch'], env=env, stdout=log, stderr=log)

    def remains_stopped(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if main_pid():
                return False
            time.sleep(.2)
        return True

    error = None
    try:
        # Compile locally: copying /bin/sleep can be rejected by macOS signature enforcement.
        host = subprocess.Popen([str(stub)], stdout=log, stderr=log)
        time.sleep(1)
        comm = subprocess.run(['/bin/ps', '-p', str(host.pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
        check('synthetic_host_alive_with_expected_executable', host.poll() is None and comm == str(stub), comm)
        for name, kwargs in [('master_off', dict(master=False)),
                             ('disabled_pet', dict(enabled=False)),
                             ('on_work', dict(mode='onWork'))]:
            configure(**kwargs)
            watcher = start_watcher()
            check(name + '_does_not_launch', remains_stopped(4.5))
            check(name + '_watcher_alive', watcher.poll() is None)
            stop_child(watcher)
            watcher = None

        configure()
        watcher = start_watcher()
        pid = wait_main()
        check('follow_app_launches_main_and_writes_isolated_pid', pid is not None)
        check('main_is_distinct_from_watcher', pid != watcher.pid)
        time.sleep(4)
        check('running_main_not_duplicated', main_pid() == pid)
        (data / 'user-quit').touch()
        stop_main()
        check('manual_quit_blocks_same_host_restart', remains_stopped(13))
        stop_child(host)
        host = subprocess.Popen([str(stub)], stdout=log, stderr=log)
        restarted = wait_main()
        check('new_host_after_quit_relaunches_main', restarted is not None and restarted != pid)
        check('relaunch_clears_manual_quit_flag', not (data / 'user-quit').exists())
        stop_child(watcher)
        watcher = None
        stop_main()
        stop_child(host)
        host = None

        configure(mode='always')
        watcher = start_watcher()
        check('always_launches_without_synthetic_host', wait_main() is not None)
        (data / 'user-quit').touch()
        stop_main()
        check('manual_quit_blocks_always_restart', remains_stopped(13))
        check('watcher_survives_all_scenarios', watcher.poll() is None)
    except Exception as exc:
        error = repr(exc)
    finally:
        stop_child(watcher)
        stop_child(host)
        stop_main()
        for pid in owned_mains:
            if pid_alive(pid):
                os.kill(pid, signal.SIGKILL)
        for domain in [suite] + [suite + '.pet.' + pet for pet in PETS + FAMILIES]:
            subprocess.run(['/usr/bin/defaults', 'delete', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log.close()
        report = dict(passed=error is None and all(row['passed'] for row in results),
                      assertions=results, error=error, failureSnapshot=failure_snapshot,
                      evidenceType='real watcher and main processes with synthetic native host; no real-client lifecycle E2E',
                      limitations=['Does not install or bootstrap the production LaunchAgent.',
                                   'Existing real Claude processes may also satisfy initial host presence; a newly started owned stub proves restart after manual quit.'],
                      finalConfiguration=json.loads((data / 'appearance.json').read_text()) if (data / 'appearance.json').exists() else None,
                      processLog=(scratch / 'process.log').read_text(errors='replace')[-12000:])
        evidence.parent.mkdir(parents=True, exist_ok=True)
        report['retainedScratch'] = str(scratch) if error else None
        evidence.write_text(json.dumps(report, indent=2, ensure_ascii=False))
        evidence.with_suffix('.log').write_text('\n'.join(
            ('PASS' if row['passed'] else 'FAIL') + ' ' + row['name'] + ' ' + row['detail']
            for row in results) + '\n' + report['processLog'])
        if not error:
            shutil.rmtree(scratch)
    if not report['passed']:
        print(error, file=sys.stderr)
        return 1
    print(f"{len(results)} assertions passed; evidence: {evidence}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

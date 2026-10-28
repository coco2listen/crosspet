#!/bin/sh
# Native window lifecycle with isolated preferences and synthetic events only.
set -eu
cd "$(dirname "$0")/.."
BIN="$PWD/build/CrossPet.app/Contents/MacOS/CrossPet"
[ -x "$BIN" ] || { echo 'Build CrossPet.app before running this probe.' >&2; exit 2; }
scratch=$(mktemp -d -t crosspet-clients-runtime)
suite="io.github.crosspet.test.clients-runtime.$(uuidgen)"
cleanup() {
  for id in single claude gpt deepseek claude-tui claude-desktop codex-tui codex-desktop dsh-desktop; do
    case "$id" in single) domain="$suite" ;; *) domain="$suite.pet.$id" ;; esac
    /usr/bin/defaults delete "$domain" >/dev/null 2>&1 || true
  done
  if [ "${CROSSPET_KEEP_PROBE_OUTPUT:-0}" != 1 ] && [ "${status:-1}" -eq 0 ]; then rm -rf "$scratch"; fi
}
trap cleanup EXIT
mkdir -p "$scratch/home" "$scratch/data" "$scratch/state"
# Both script and native entry point validate test isolation; no process-name kill is used.
set +e
env CFFIXED_USER_HOME="$scratch/home" CROSSPET_PREFERENCES_SUITE="$suite" \
  CROSSPET_DATA_DIR="$scratch/data" CROSSPET_STATE_DIR="$scratch/state" \
  CROSSPET_PROBE_OUTPUT="$scratch/result.json" \
  python3 - "$BIN" "$scratch/runtime.log" <<'PYRUN'
import subprocess, sys
with open(sys.argv[2], 'w', encoding='utf-8') as log:
    try:
        result = subprocess.run([sys.argv[1], '--runtime-probe'], stdout=log, stderr=subprocess.STDOUT, timeout=45)
        raise SystemExit(result.returncode)
    except subprocess.TimeoutExpired:
        # subprocess.run kills only the child it started, never a process selected by name.
        print('Probe-owned App exceeded its 45-second launch/runtime deadline.', file=log)
        raise SystemExit(124)
PYRUN
status=$?
set -e
echo "Probe output: $scratch"
if [ -f "$scratch/result.json" ]; then
  set +e
  python3 - "$scratch/result.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    result = json.load(stream)
print(f"Native client windows: {len(result['checks'])} checks, {len(result['failures'])} failures")
for failure in result['failures']:
    print('FAIL:', failure)
for evidence in result.get('failureEvidence', []):
    print('ACTUAL:', json.dumps(evidence, ensure_ascii=False, sort_keys=True))
if not result['ok']:
    raise SystemExit(1)
PY
  report_status=$?
  set -e
  if [ "$report_status" -ne 0 ]; then status=1; fi
else
  cat "$scratch/runtime.log" >&2
  echo 'Runtime probe produced no JSON result.' >&2
  status=1
fi
if [ "$status" -ne 0 ]; then cat "$scratch/runtime.log" >&2; fi
exit "$status"

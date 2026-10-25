#!/bin/sh
# Real NSPanel/WKWebView checks across two process launches. No mouse automation.
set -eu
cd "$(dirname "$0")/.."
# CROSSPET_PROBE_MODE=clients runs the five-client pets; the default is the three-family pets.
MODE=${CROSSPET_PROBE_MODE:-families}
case "$MODE" in families) PETS="claude gpt deepseek" ;; clients) PETS="claude-tui claude-desktop codex-tui codex-desktop dsh-desktop" ;; *) echo 'mode: families|clients' >&2; exit 2 ;; esac
OUT=${1:?provide an absolute evidence directory}
case "$OUT" in /*) ;; *) echo 'absolute evidence path required' >&2; exit 2 ;; esac
BIN="$PWD/build/CrossPet.app/Contents/MacOS/CrossPet"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/crosspet-runtime.XXXXXX")
SUITE="io.github.crosspet.test.persistence.$$"
cleanup() {
  for domain in "$SUITE" $(for p in claude gpt deepseek claude-tui claude-desktop codex-tui codex-desktop dsh-desktop; do echo "$SUITE.pet.$p"; done); do /usr/bin/defaults delete "$domain" >/dev/null 2>&1 || true; done
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
mkdir -p "$OUT" "$SCRATCH/home" "$SCRATCH/data" "$SCRATCH/state"
touch "$SCRATCH/data/ai-autostart-off"
cat > "$SCRATCH/seed.swift" <<'SWIFT'
import Foundation
let suite = CommandLine.arguments[1]
let root = UserDefaults(suiteName: suite)!
root.set(CommandLine.arguments[2], forKey: "petMode"); root.synchronize()
for (i, family) in CommandLine.arguments.dropFirst(3).enumerated() {
    let prefs = UserDefaults(suiteName: suite + ".pet." + family)!
    prefs.set(1, forKey: "familySchema")
    prefs.set([100.0 + Double(i) * 300, 100.0], forKey: "origin")
    prefs.set([0.8, 0.9, 1.1, 1.0, 1.2][i], forKey: "size")
    prefs.synchronize()
}
SWIFT
swift "$SCRATCH/seed.swift" "$SUITE" "$MODE" $PETS
for pass in 1 2; do
  mkdir -p "$OUT/pass-$pass"
  env CFFIXED_USER_HOME="$SCRATCH/home" CROSSPET_PREFERENCES_SUITE="$SUITE" CROSSPET_DATA_DIR="$SCRATCH/data" CROSSPET_STATE_DIR="$SCRATCH/state" CROSSPET_PROBE_MODE="$MODE" CROSSPET_PROBE_OUTPUT="$OUT/pass-$pass/runtime.json" "$BIN" --runtime-probe > "$OUT/pass-$pass/runtime.log" 2>&1
done
python3 - "$OUT" $PETS <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); pets=sys.argv[2:]; reports=[json.loads((root/f'pass-{n}/runtime.json').read_text()) for n in [1,2]]
for report in reports:
 assert report['passed'], [a for a in report['assertions'] if not a['passed']]
 initial={p['pet']:p for p in report['stages'][0]['pages']}
 for i,pet in enumerate(pets):
  page=initial[pet]
  assert abs(page['pageZoom']-[.8,.9,1.1,1.0,1.2][i])<.001, (pet,page['pageZoom'])
  assert page['frame'][:2]==[100+i*300,100],(pet,page['frame'])
summary={'passed':True,'processLaunches':2,'assertionsPerLaunch':[len(r['assertions']) for r in reports],'persisted':['independent_origin','independent_scale'],'limitations':['programmatic window operations, not real mouse dragging','no hours-long stability claim']}
(root/'restart-summary.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary))
PY

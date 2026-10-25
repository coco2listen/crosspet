#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    checks += 1
}
func snapshot(_ overrides: [String: Any] = [:]) -> Data {
    var value: [String: Any] = ["schema": 1, "family": "deepseek", "source": "deepseek-harness",
        "client": "desktop", "sessionId": "same-session", "model": "claude-test",
        "status": "Thinking", "pose": "thinking", "event": "PreInvocation",
        "ts": 1000.0, "observedAt": 1000.0, "sequence": 1, "producerId": "process-a", "pid": 123]
    for (key, entry) in overrides { value[key] = entry }
    return try! JSONSerialization.data(withJSONObject: value)
}
let ds = FamilyState(family: "deepseek")
check(ds.aggregate().status == "Unknown", "no producer is neither success nor proven Offline")
check(ds.aggregate().payload["confidence"] as? String == "unknown", "no sessions does not claim observed process exit")
check(ds.ingest(snapshot()), "valid snapshot")
check(ds.aggregate(now: 1000).status == "Thinking", "route by host despite Claude model")
check(!FamilyState(family: "claude").ingest(snapshot()), "DSH cannot enter Claude reducer")
check(!ds.ingest(snapshot(["source": "claude-code"])), "forged family cannot override source binding")
check(!ds.ingest(snapshot()), "duplicate ignored")
check(!ds.ingest(snapshot(["sequence": 0, "observedAt": 1001.0])), "out of order sequence ignored")
check(!ds.ingest(snapshot(["sequence": 3, "observedAt": 1001.0, "ts": 999.0])), "late source timestamp rejected despite higher delivery sequence")
check(ds.aggregate(now: 2000).status == "Unknown", "silence is uncertainty, never success or offline")
check(ds.aggregate(now: 2000).stale, "silence is marked stale")
check(!ds.ingest(snapshot(["status": "Success", "event": "Timeout", "sequence": 2])), "timeout cannot assert success")
check(!ds.ingest(Data("not JSON".utf8)), "partial or corrupt write ignored")
check(ds.ingest(snapshot(["sequence": 2, "turnId": "turn-a", "status": "Success", "pose": "happy", "event": "turn/end"])), "explicit completion")
check(ds.aggregate(now: 1001).status == "Success", "success visible")
check(ds.aggregate(now: 1004).status == "Idle", "completion animation expires to idle presentation")
check(ds.records.values.first?.status == "Success", "completion record remains truthful")
check(ds.aggregate(now: 1004).payload["recordedStatus"] as? String == "Success", "presentation carries recorded completion")
check(!ds.ingest(snapshot(["sequence": 3, "turnId": "turn-a"])), "late tool after completed turn rejected")
check(ds.ingest(snapshot(["sequence": 4, "turnId": "turn-b", "observedAt": 1002.0, "ts": 1002.0])), "new turn allowed")
check(ds.ingest(snapshot(["sessionId": "second", "status": "Waiting Input", "pose": "asking"])), "concurrent session")
check(ds.aggregate(now: 1002).status == "Waiting Input", "input outranks work")
check(ds.ingest(snapshot(["sessionId": "third", "status": "Waiting Permission", "pose": "asking"])), "permission session")
check(ds.aggregate(now: 1002).status == "Waiting Permission", "permission outranks input")
check(ds.ingest(snapshot(["sessionId": "fourth", "status": "Error", "pose": "oops"])), "error session")
check(ds.aggregate(now: 1002).count == 4, "sessions independent")
check(!ds.markProcessExited(key: ds.records.values.first!.key, producerId: "wrong"), "wrong process cannot terminate session")
for record in ds.records.values {
    check(ds.markProcessExited(key: record.key, producerId: "process-a", now: 1003), "observed process exit")
}
check(ds.aggregate(now: 1004).status == "Offline", "all producers exited")
check(ds.aggregate(now: 1004).count == 0, "offline sessions excluded from count")
check(ds.ingest(snapshot(["producerId": "process-b", "sequence": 1, "turnId": "turn-b", "ts": 1005.0, "observedAt": 1005.0])), "restart resets sequence and closed turns")
check(!ds.ingest(snapshot(["producerId": "old-process", "sequence": 100, "observedAt": 999.0, "ts": 999.0])), "old producer cannot overwrite restart")
let combined = FamilyState(family: "gpt")
check(combined.ingest(snapshot(["family": "gpt", "source": "codex", "client": "tui", "sessionId": "s"])), "Codex TUI")
check(combined.ingest(snapshot(["family": "gpt", "source": "codex", "client": "desktop", "sessionId": "s", "sequence": 2])), "same session name from desktop")
check(combined.sessions(now: 1000).count == 2, "client source identity separates same-named sessions")
check(!combined.ingest(snapshot(["family": "gpt", "source": "codex", "client": "invented"])), "unknown frontend is explicit")
check(!combined.ingest(snapshot(["family": "gpt", "source": "codex", "status": "Maybe"])), "invalid status rejected")
let tie = FamilyState(family: "deepseek")
check(tie.ingest(snapshot(["sessionId": "a"])), "tie a")
check(tie.ingest(snapshot(["sessionId": "b", "status": "Tool Running", "pose": "running"])), "tie b")
check(tie.aggregate(now: 1000).status == "Tool Running", "tool outranks thinking")
check(tie.ingest(snapshot(["sessionId": "c", "status": "Error", "pose": "oops"])), "tie c")
check(tie.aggregate(now: 1000).status == "Error", "error outranks tool")
let terminal = FamilyState(family: "deepseek")
check(terminal.ingest(snapshot(["status": "Error", "pose": "oops", "event": "turn/end"])), "terminal error")
check(terminal.ingest(snapshot(["sessionId": "ongoing", "status": "Tool Running", "pose": "running"])), "work beside terminal error")
check(terminal.aggregate(now: 1001).status == "Error", "recent error receives visible acknowledgement")
check(terminal.aggregate(now: 1004).status == "Tool Running", "old terminal error cannot obscure ongoing session")
check(terminal.records.values.contains { $0.status == "Error" }, "terminal error history preserved")
check(terminal.ingest(snapshot(["sessionId": "finished", "status": "Success", "pose": "happy", "event": "Stop"])), "terminal success beside work")
check(terminal.aggregate(now: 1200).status == "Unknown", "quiet work becomes unconfirmed, not completed")
check(terminal.aggregate(now: 1200).stale, "ongoing work retains stale evidence")
let resultState = FamilyState(family: "deepseek")
check(resultState.ingest(snapshot(["status": "Offline", "pose": "sleeping", "event": "SessionEnd", "lastResult": ["status": "Success", "pose": "happy", "event": "Stop", "ts": 999.0]])), "explicit result carried with session end")
check(resultState.aggregate(now: 1000).status == "Offline", "result notification cannot overwrite current Offline status")
check(resultState.aggregate(now: 1000).payload["lastResult"] != nil, "completed turn is available for animation")
check(resultState.aggregate(now: 1011).payload["lastResult"] == nil, "old result cannot replay on app restart")
let fakeResult = FamilyState(family: "deepseek")
check(fakeResult.ingest(snapshot(["lastResult": ["status": "Success", "pose": "happy", "event": "Timeout", "ts": 999.0]])), "snapshot may ignore invalid result notification")
check(fakeResult.aggregate(now: 1000).payload["lastResult"] == nil, "silence cannot manufacture a successful notification")
let tui = FamilyState(family: "claude", client: "tui"), desk = FamilyState(family: "claude", client: "desktop")
func claude(_ client: String, _ id: String = "s1") -> Data { snapshot(["family": "claude", "source": "claude-code", "client": client, "sessionId": id]) }
check(tui.ingest(claude("tui")) && !desk.ingest(claude("tui")), "client filter routes a session to exactly one pet")
check(desk.ingest(claude("desktop")) && !tui.ingest(claude("desktop", "s2")), "desktop session never reaches the TUI pet")
check(!tui.ingest(claude("unknown", "s3")) && tui.aggregate(now: 1000).payload["unattributed"] as? Int == 1, "unknown client is surfaced, never guessed")
check(FamilyState(family: "claude").ingest(claude("unknown", "s4")), "three-family mode still accepts every client")
let idle = FamilyState(family: "claude", client: "desktop")
check(idle.aggregate().status == "Unknown" && idle.aggregate().event == "NoSessions", "no events is Unknown, not Offline")
let historical = FamilyState(family: "claude", client: "tui")
let oldUnknown = snapshot(["family": "claude", "source": "claude-code", "client": "unknown", "sessionId": "legacy", "ts": 1000.0, "observedAt": 1000.0])
check(!historical.ingest(oldUnknown), "unknown origin not routed")
check(historical.aggregate(now: 1100).payload["unattributed"] as? Int == 1, "recent unknown counted")
check(historical.aggregate(now: 1300).payload["unattributed"] == nil, "historical unknown expires from badge without deleting evidence")
check(historical.ingest(snapshot(["family": "claude", "source": "claude-code", "client": "tui", "sessionId": "legacy", "status": "Success", "event": "Stop", "ts": 1001.0, "observedAt": 1001.0])), "same session later carries explicit client proof")
check(historical.aggregate(now: 1100).payload["unattributed"] == nil, "unique explicit identity resolves old unknown warning")
let endedUnknown = FamilyState(family: "gpt", client: "desktop")
check(!endedUnknown.ingest(snapshot(["family": "gpt", "source": "codex", "client": "unknown", "status": "Offline", "event": "SessionEnd"])), "unattributed ended session not routed")
check(endedUnknown.aggregate(now: 1001).payload["unattributed"] == nil, "ended unknown never counted")
let freshness = FamilyState(family: "deepseek")
check(freshness.ingest(snapshot()), "old thinking fixture")
check(freshness.ingest(snapshot(["sessionId": "new-completed", "status": "Success", "event": "turn/end", "ts": 1300.0, "observedAt": 1300.0])), "new completion fixture")
check(freshness.aggregate(now: 1301).status == "Success", "stale thinking cannot obscure fresh completion")
check(freshness.aggregate(now: 1305).status == "Idle", "completed task settles despite stale old sessions")
let stalePayload = ds.sessions(now: 2000).values.first { $0["status"] as? String == "Unknown" }
check(stalePayload?["event"] as? String == "StateStale" && stalePayload?["pose"] as? String == "sleeping", "stale events cannot schedule delayed thinking or work animations")
let diagnosticOrder = FamilyState(family: "claude", client: "desktop")
let diagnosticBase: [String: Any] = ["family": "claude", "source": "claude-code", "client": "unknown", "sessionId": "unknown-order"]
func diagnostic(_ values: [String: Any]) -> Data { snapshot(diagnosticBase.merging(values) { _, new in new }) }
_ = diagnosticOrder.ingest(diagnostic(["sequence": 2]))
check(diagnosticOrder.aggregate(now: 1002).payload["unattributed"] as? Int == 1, "open unknown diagnostic")
_ = diagnosticOrder.ingest(diagnostic(["sequence": 3, "status": "Offline", "event": "SessionEnd", "ts": 1001.0, "observedAt": 1001.0]))
check(diagnosticOrder.aggregate(now: 1002).payload["unattributed"] == nil, "unknown session ended")
_ = diagnosticOrder.ingest(diagnostic(["sequence": 1, "ts": 999.0, "observedAt": 1002.0]))
check(diagnosticOrder.aggregate(now: 1002).payload["unattributed"] == nil, "older timestamp and sequence cannot revive unknown warning")
let interruptedUnknown = FamilyState(family: "claude", client: "desktop")
_ = interruptedUnknown.ingest(diagnostic(["status": "Idle", "event": "Stop", "pose": "surprised"]))
check(interruptedUnknown.aggregate(now: 1001).payload["unattributed"] == nil, "interrupted or compacted unknown turn no longer warned")
let classified = FamilyState(family: "claude", client: "tui")
check(!classified.ingestResult(Data("{".utf8)).cacheable, "incomplete JSON remains retryable")
check(!classified.ingestResult(snapshot(["schema": 2])).cacheable, "invalid schema remains retryable")
check(classified.ingestResult(claude("desktop", "foreign-valid")).cacheable && classified.records.isEmpty, "valid other client can cache without routing")
check(classified.ingestResult(claude("unknown", "unknown-valid")).cacheable && classified.aggregate(now: 1000).payload["unattributed"] as? Int == 1, "valid unknown can cache after diagnostics update")
check(classified.ingestResult(claude("tui", "own-valid")).appliedSnapshot != nil, "applied result carries the already decoded snapshot")
check(classified.ingestResult(claude("tui", "own-valid")).cacheable, "unchanged duplicate is cacheable")
print("FamilyState: \(checks) checks passed")
SWIFT
swiftc app/mac/FamilyState.swift "$scratch/main.swift" -o "$scratch/family-state-probe"
"$scratch/family-state-probe"

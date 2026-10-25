#!/bin/sh
# Real temp files + production reducer: validation and cache eligibility, no user state writes.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    guard value() else { fputs("FAIL: \(label)\n", stderr); exit(1) }; checks += 1
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("states")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let state = FamilyState(family: "claude", client: "tui")
var cache: [String: Date] = [:]
func data(_ client: String, _ sid: String, _ extra: [String: Any] = [:]) -> Data {
    let row: [String: Any] = ["schema": 1, "family": "claude", "source": "claude-code", "client": client,
        "sessionId": sid, "model": "test", "status": "Thinking", "pose": "thinking", "event": "PreInvocation",
        "ts": 1000.0, "observedAt": 1000.0, "sequence": 1, "producerId": "process-a"]
    return try! JSONSerialization.data(withJSONObject: row.merging(extra) { _, next in next })
}
func write(_ name: String, _ bytes: Data, _ stamp: Double) {
    let url = folder.appendingPathComponent(name)
    try! bytes.write(to: url)
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: stamp)], ofItemAtPath: url.path)
}
func poll() -> Int {
    var reads = 0
    for file in try! FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
        guard let stamp = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              stamp != cache[file.path], let bytes = try? Data(contentsOf: file) else { continue }
        reads += 1
        let result = state.ingestResult(bytes)
        if result.cacheable { cache[file.path] = stamp }
    }
    return reads
}
write("own.json", data("tui", "own"), 1000)
write("foreign.json", data("desktop", "foreign"), 1000)
write("unknown.json", data("unknown", "unresolved"), 1000)
check(poll() == 3, "first cycle parses every file")
check(poll() == 0, "unchanged own/foreign/unknown files cause zero repeat decodes")
check(state.records.count == 1 && state.records.values.first?.client == "tui", "cached foreign client cannot leak into pet")
check(state.aggregate(now: 1001).payload["unattributed"] as? Int == 1, "cached unknown still contributes diagnostics")
check(state.aggregate(now: 1200).payload["unattributed"] == nil, "unknown expiry needs no file reread")
check(state.aggregate(now: 1200).status == "Unknown", "staleness deadline survives caching")
write("own.json", data("tui", "own", ["status": "Success", "pose": "happy", "event": "Stop", "ts": 1001.0, "observedAt": 1001.0, "sequence": 2]), 1001)
check(poll() == 1, "changed file is decoded on next poll")
check(state.aggregate(now: 1002).status == "Success", "completion updates immediately")
check(state.aggregate(now: 1005).status == "Idle", "four-second completion settles without file reread")
check(poll() == 0, "completion does not require repetitive decoding")
write("own.json", data("tui", "own", ["sequence": 1, "ts": 999.0, "observedAt": 1002.0]), 1002)
check(poll() == 1 && state.records.values.first?.status == "Success", "older event is read but cannot revive Thinking")
check(poll() == 0, "validated rejected old event is cached")
write("broken.json", Data("{".utf8), 2000)
check(poll() == 1 && poll() == 1, "partial write is retried despite unchanged mtime")
write("broken.json", data("tui", "repaired"), 2000)
check(poll() == 1 && state.records.count == 2, "repair with the same mtime is recovered")
check(poll() == 0, "successfully repaired snapshot then caches")
write("resolved.json", data("tui", "unresolved", ["status": "Offline", "pose": "sleeping", "event": "SessionEnd", "ts": 1002.0, "observedAt": 1002.0]), 2001)
check(poll() == 1, "new identity evidence is observed")
check(state.aggregate(now: 1003).payload["unattributed"] == nil, "cached unknown warning resolves from unique known client")
print("Family cache: \(checks) checks passed")
SWIFT
swiftc app/mac/FamilyState.swift "$scratch/main.swift" -o "$scratch/family-cache-probe"
"$scratch/family-cache-probe" "$scratch"

#!/bin/sh
# Pure filesystem probe: no App, preferences, clients or live state directory.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/crosspet-client-cache.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation
import Darwin

var passed = 0
var failures: [String] = []
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { passed += 1 }
    else { failures.append(name); fputs("FAIL \(name)\n", stderr) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
let cache = SnapshotFileCache()
let stamp = Date(timeIntervalSince1970: 1_700_000_000)
func write(_ name: String, _ text: String) -> URL {
    let url = root.appendingPathComponent(name)
    try! Data(text.utf8).write(to: url)
    try! fileManager.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
    return url
}
func inode(_ url: URL) -> UInt64 {
    (try! fileManager.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber).uint64Value
}
var consumed: [String] = []
func accept(_ data: Data) -> Bool { consumed.append(String(decoding: data, as: UTF8.self)); return true }

let valid = write("valid.json", "valid")
cache.read(valid, consume: accept)
check("first valid snapshot is read", cache.readCount == 1)
check("first valid snapshot reaches consumer", consumed == ["valid"])
for _ in 0..<4 { cache.read(valid, consume: accept) }
check("repeated polls use signature cache", cache.readCount == 1)
check("cached snapshots are not consumed again", consumed.count == 1)

let ignored = write("ignored.json", "ignored")
var ignoredCalls = 0
for _ in 0..<4 { cache.read(ignored) { _ in ignoredCalls += 1; return true } }
check("valid ignored snapshot is consumed once", ignoredCalls == 1)
check("valid ignored snapshot is cached", cache.readCount == 2)

let invalid = write("invalid.json", "bad")
var invalidCalls = 0
for _ in 0..<3 { cache.read(invalid) { _ in invalidCalls += 1; return false } }
check("invalid snapshot is retried each poll", invalidCalls == 3)
check("invalid retries perform fresh reads", cache.readCount == 5)
let beforeRepairInode = inode(invalid)
_ = write("invalid.json", "new")
check("repair fixture keeps the same inode", inode(invalid) == beforeRepairInode)
var repaired = ""
cache.read(invalid) { repaired = String(decoding: $0, as: UTF8.self); return repaired == "new" }
check("invalid same-stamp same-size repair is consumed", repaired == "new")
check("repaired file incurs one read", cache.readCount == 6)
cache.read(invalid) { _ in failures.append("repaired snapshot was not cached"); return true }
check("repaired file becomes cached", cache.readCount == 6)

// Seeing absence invalidates a path even if a later file has identical metadata.
try! fileManager.removeItem(at: valid)
var missingCalls = 0
cache.read(valid) { _ in missingCalls += 1; return true }
check("missing file does not invoke the consumer", missingCalls == 0)
check("missing file does not count as a byte read", cache.readCount == 6)
_ = write("valid.json", "valid")
cache.read(valid, consume: accept)
check("delete and recreate rereads snapshot", cache.readCount == 7)
check("recreated snapshot is delivered", consumed == ["valid", "valid"])

// Atomic replace can preserve mtime and length; inode is the differentiating evidence.
let beforeAtomicInode = inode(valid)
let replacement = write("replacement.json", "fresh")
check("atomic fixture uses a distinct inode", inode(replacement) != beforeAtomicInode)
check("atomic rename succeeds", Darwin.rename(replacement.path, valid.path) == 0)
cache.read(valid, consume: accept)
check("same-stamp same-size atomic replacement is read", cache.readCount == 8)
check("atomic replacement reaches consumer", consumed.last == "fresh")
cache.read(valid, consume: accept)
check("atomic replacement becomes cached", cache.readCount == 8)

// A changed signature which is rejected must invalidate even the old successful signature.
_ = write("valid.json", "longer")
cache.read(valid) { _ in false }
check("changed invalid replacement is read", cache.readCount == 9)
_ = write("valid.json", "valid")
cache.read(valid, consume: accept)
check("repair restoring an older signature still rereads", cache.readCount == 10)
check("restored-size repair reaches consumer", consumed.last == "valid")

cache.retain([valid.path])
cache.read(valid, consume: accept)
check("retain keeps enumerated cache entries", cache.readCount == 10)
cache.read(ignored) { _ in ignoredCalls += 1; return true }
check("retain evicts omitted paths", cache.readCount == 11 && ignoredCalls == 2)
cache.retain([])
cache.read(valid, consume: accept)
check("empty enumeration evicts all paths", cache.readCount == 12)
cache.reset()
cache.read(valid, consume: accept)
check("reset invalidates consumer-lifetime cache", cache.readCount == 13)
cache.read(valid, consume: accept)
check("reset preserves cumulative read diagnostics", cache.readCount == 13)

let result: [String: Any] = ["passed": passed, "failed": failures.count, "failures": failures, "readCount": cache.readCount]
let output = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: output, as: UTF8.self))
if !failures.isEmpty { exit(1) }
SWIFT
swiftc app/mac/SnapshotFileCache.swift "$scratch/main.swift" -o "$scratch/client-cache-probe"
"$scratch/client-cache-probe" "$scratch"

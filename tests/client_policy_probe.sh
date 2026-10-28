#!/bin/sh
# The same metadata fixture must give identical answers in Node and JavaScriptCore.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d -t crosspet-client-policy)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation
import JavaScriptCore
let arguments = CommandLine.arguments
let context = JSContext()!
let source = try String(contentsOfFile: arguments[1], encoding: .utf8)
let fixtureText = try String(contentsOfFile: arguments[2], encoding: .utf8)
context.evaluateScript(source)
context.setObject(fixtureText, forKeyedSubscript: "fixtureJSON" as NSString)
let answer = context.evaluateScript("const fixture = JSON.parse(fixtureJSON); const state = fixture.snapshots.reduce((s,row) => ClientPolicy.ingest(s,row,fixture.scope).state,{}); JSON.stringify({aggregate:ClientPolicy.aggregate(state,fixture.now,fixture.scope),hosts:ClientPolicy.hosts(fixture.processes)})")
guard context.exception == nil, let text = answer?.toString() else { fatalError(context.exception?.toString() ?? "JavaScriptCore failed") }
print(text)
SWIFT
swiftc "$scratch/main.swift" -framework JavaScriptCore -o "$scratch/policy-probe"
"$scratch/policy-probe" "$PWD/app/web/client-policy.js" "$PWD/tests/fixtures/client-policy.json" > "$scratch/jsc.json"
node - "$PWD" "$scratch/jsc.json" <<'JS'
const fs = require('node:fs'), assert = require('node:assert/strict')
const base = process.argv[2]
const P = require(base + '/app/web/client-policy.js')
const fixture = require(base + '/tests/fixtures/client-policy.json')
const state = fixture.snapshots.reduce((s,row) => P.ingest(s,row,fixture.scope).state,{})
const expected = { aggregate: P.aggregate(state,fixture.now,fixture.scope), hosts: P.hosts(fixture.processes) }
assert.deepEqual(expected.aggregate, fixture.expected)
assert.deepEqual(expected.hosts, fixture.expectedHosts)
assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[3], 'utf8')), expected)
console.log('Client policy: JavaScriptCore and Node aggregate/host fixtures match (2 comparisons)')
JS

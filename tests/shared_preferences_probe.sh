#!/bin/sh
# Pure Foundation migration checks in disposable preference domains; no clients or credentials.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/crosspet-preferences.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation

var count = 0
var failures: [String] = []
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    count += 1
    if !condition() { failures.append(label) }
}
let domain = "io.github.crosspet.test.migration.\(UUID().uuidString)"
let ids = ["codex-desktop", "claude-desktop", "codex-tui", "claude-tui", "dsh-desktop", "gpt", "claude", "deepseek"]
let shared = UserDefaults(suiteName: domain)!
func legacy(_ id: String) -> UserDefaults { UserDefaults(suiteName: domain + ".pet." + id)! }
func clean() {
    for name in [domain] + ids.map({ domain + ".pet." + $0 }) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}
clean()
defer { clean() }
shared.set(false, forKey: "gptQuota")
shared.set(false, forKey: "codexResets")
shared.set(0.8, forKey: "size")
shared.set([2.0, 3.0], forKey: "origin")
legacy("codex-desktop").set(true, forKey: "gptQuota")
legacy("codex-desktop").set(true, forKey: "codexResets")
legacy("codex-desktop").set(false, forKey: "eggs")
legacy("codex-desktop").set(1.2, forKey: "size")
legacy("codex-desktop").set([50.0, 60.0], forKey: "origin")
legacy("codex-desktop").set(false, forKey: "enabled")
legacy("codex-desktop").set(true, forKey: "hidden")
legacy("claude-desktop").set(false, forKey: "showName")
legacy("claude-desktop").set(true, forKey: "eggs")
legacy("claude-desktop").set("followApp", forKey: "appearanceMode")
legacy("claude-tui").set(true, forKey: "showName")
legacy("gpt").set(true, forKey: "textLinked")
shared.set(false, forKey: "textLinked")
let oldRoot = shared.persistentDomain(forName: domain)!
let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, legacy($0).persistentDomain(forName: domain + ".pet." + $0) ?? [:]) })
SharedPreferences.migrate(domain: domain, shared: shared)
check(shared.object(forKey: "gptQuota") as? Bool == true, "GPT Desktop explicit quota enabled survives")
check(shared.object(forKey: "codexResets") as? Bool == true, "GPT Desktop explicit reset reminders enabled survive")
check(shared.object(forKey: "eggs") as? Bool == false, "higher-priority explicit false wins over lower-priority true")
check(shared.object(forKey: "showName") as? Bool == false, "absent key falls back to next explicit false")
check(shared.string(forKey: "appearanceMode") == "followApp", "appearance mode follows same deterministic key precedence")
check(abs(shared.double(forKey: "size") - 1.2) < 0.001, "numeric value uses same source priority")
check(shared.object(forKey: "textLinked") as? Bool == true, "family value wins over root when client key absent")
check(shared.object(forKey: "powerSave") == nil, "never-set boolean remains absent")
check(shared.array(forKey: "origin") as? [Double] == [2, 3], "root window position is not migrated from a pet")
check(shared.object(forKey: "enabled") == nil, "per-pet enable is not promoted to shared settings")
check(shared.object(forKey: "hidden") as? Bool == true, "manual hide migrates to the shared setting")
let backup = shared.dictionary(forKey: "sharedSettingsBackupV1")!
check(NSDictionary(dictionary: backup[domain] as! [String: Any]).isEqual(to: oldRoot), "root pre-migration values backed up exactly")
for id in ids {
    check(NSDictionary(dictionary: backup[domain + ".pet." + id] as! [String: Any]).isEqual(to: before[id]!), "legacy domain backed up exactly: \(id)")
}
check((shared.dictionary(forKey: "sharedSettingsSourcesV1")?["gptQuota"] as? String) == domain + ".pet.codex-desktop", "chosen source retained for conflict explanation")
for id in ids {
    let after = legacy(id).persistentDomain(forName: domain + ".pet." + id) ?? [:]
    check(NSDictionary(dictionary: before[id]!).isEqual(to: after), "legacy domain retained unchanged: \(id)")
}
shared.set(false, forKey: "gptQuota")
shared.set(false, forKey: "codexResets")
legacy("codex-desktop").set(1.5, forKey: "size")
SharedPreferences.migrate(domain: domain, shared: shared)
check(shared.object(forKey: "gptQuota") as? Bool == false, "later explicit quota-off is not overwritten on restart")
check(shared.object(forKey: "codexResets") as? Bool == false, "later explicit reminders-off is not overwritten on restart")
check(abs(shared.double(forKey: "size") - 1.2) < 0.001, "migration is one-time despite changed legacy value")
check(oldRoot["gptQuota"] as? Bool == false, "test fixture captured conflicting root value")
clean()
if !failures.isEmpty {
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    exit(1)
}
print("Shared preferences migration: \(count) checks passed (disposable UserDefaults domains)")
SWIFT
swiftc app/mac/SharedPreferences.swift "$scratch/main.swift" -o "$scratch/shared-preferences-probe"
"$scratch/shared-preferences-probe"

#!/bin/sh
# Compile only the preferences migration; never start CrossPet or touch its real suites.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/crosspet-client-preferences.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/home"
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation

var passed = 0
var failed: [String] = []
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { passed += 1 }
    else { failed.append(name); fputs("FAIL \(name)\n", stderr) }
}
let prefix = "io.github.crosspet.test.client-preferences.\(UUID().uuidString)"
var suites: [String] = []
func suite(_ suffix: String, _ values: [String: Any] = [:]) -> (String, UserDefaults) {
    let name = "\(prefix).\(suffix)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.setPersistentDomain(values, forName: name)
    defaults.synchronize()
    suites.append(name)
    return (name, defaults)
}
func legacy(_ domain: String, _ id: String, _ values: [String: Any]) -> UserDefaults {
    let name = "\(domain).pet.\(id)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.setPersistentDomain(values, forName: name)
    defaults.synchronize()
    suites.append(name)
    return defaults
}
defer {
    for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
}

// A fresh install must not acquire a choice merely by preparing compatible settings.
let (freshDomain, fresh) = suite("fresh")
SharedPreferences.migrate(domain: freshDomain, shared: fresh)
let (_, freshPet) = suite("fresh-pet")
SharedPreferences.migratePet(freshPet, family: "claude", shared: fresh)
check("fresh migration does not enable multi-pet mode", fresh.object(forKey: "petMode") == nil)
check("fresh migration does not invent a pet enabled preference", freshPet.object(forKey: "enabled") == nil)
check("fresh size uses normal default", freshPet.double(forKey: "size") == 1)
check("fresh outfit is original", freshPet.string(forKey: "outfitV1") == "")

// Once V1 selected a shared value, a stale pet suite may not override it.
let (v1Domain, v1) = suite("v1", ["sharedSettingsSchema": 1, "gptQuota": false, "codexResets": false, "hidden": false])
_ = legacy(v1Domain, "codex-desktop", ["gptQuota": true, "codexResets": true, "hidden": true])
SharedPreferences.migrate(domain: v1Domain, shared: v1)
check("V1 preserves explicit GPT quota false", v1.object(forKey: "gptQuota") as? Bool == false)
check("V1 preserves explicit resets false", v1.object(forKey: "codexResets") as? Bool == false)
check("V1 preserves explicit hidden false", v1.object(forKey: "hidden") as? Bool == false)
check("V1 does not create a second migration backup", v1.object(forKey: "sharedSettingsBackupV1") == nil)
v1.set(true, forKey: "gptQuota"); v1.set(true, forKey: "codexResets")
SharedPreferences.migrate(domain: v1Domain, shared: v1)
check("V1 keeps explicitly enabled GPT quota", v1.object(forKey: "gptQuota") as? Bool == true)
check("V1 keeps explicitly enabled Codex resets", v1.object(forKey: "codexResets") as? Bool == true)

// Unmigrated domains use the documented deterministic source order, never boolean OR.
let (domain, shared) = suite("legacy", ["gptQuota": false, "codexResets": false, "hidden": true, "showName": false, "size": 1.2, "skins": ["claude": "claude-hoodie"]])
let desktop = legacy(domain, "codex-desktop", ["gptQuota": true, "codexResets": true, "hidden": false])
let claudeDesktop = legacy(domain, "claude-desktop", ["hidden": true, "powerSave": false])
_ = legacy(domain, "codex-tui", ["powerSave": true, "quotaAggregate": false])
_ = legacy(domain, "claude-tui", ["quotaAggregate": true, "textLinked": false])
_ = legacy(domain, "dsh-desktop", ["textLinked": true, "eggs": false])
_ = legacy(domain, "gpt", ["eggs": true, "edgeDock": false])
_ = legacy(domain, "claude", ["edgeDock": true, "followApps": false])
_ = legacy(domain, "deepseek", ["followApps": true])
SharedPreferences.migrate(domain: domain, shared: shared)
check("unmigrated GPT quota explicit true retained", shared.object(forKey: "gptQuota") as? Bool == true)
check("unmigrated Codex resets explicit true retained", shared.object(forKey: "codexResets") as? Bool == true)
check("codex desktop wins with explicit false", shared.object(forKey: "hidden") as? Bool == false)
check("claude desktop outranks codex terminal", shared.object(forKey: "powerSave") as? Bool == false)
check("codex terminal outranks claude terminal", shared.object(forKey: "quotaAggregate") as? Bool == false)
check("claude terminal outranks DSH", shared.object(forKey: "textLinked") as? Bool == false)
check("DSH outranks legacy GPT", shared.object(forKey: "eggs") as? Bool == false)
check("legacy GPT outranks legacy Claude", shared.object(forKey: "edgeDock") as? Bool == false)
check("legacy Claude outranks legacy DeepSeek", shared.object(forKey: "followApps") as? Bool == false)
check("root is fallback when no pet set key", shared.object(forKey: "showName") as? Bool == false)
check("shared migration marked V1", shared.integer(forKey: "sharedSettingsSchema") == 1)
let backup = shared.dictionary(forKey: "sharedSettingsBackupV1") ?? [:]
check("backup retains original root false", (backup[domain] as? [String: Any])?["gptQuota"] as? Bool == false)
check("backup retains desktop true", (backup["\(domain).pet.codex-desktop"] as? [String: Any])?["gptQuota"] as? Bool == true)
check("old desktop domain remains untouched", desktop.object(forKey: "hidden") as? Bool == false)
check("old Claude desktop domain remains untouched", claudeDesktop.object(forKey: "hidden") as? Bool == true)
let sources = shared.dictionary(forKey: "sharedSettingsSourcesV1") as? [String: String] ?? [:]
check("records selected desktop source", sources["hidden"] == "\(domain).pet.codex-desktop")
check("records root fallback source", sources["showName"] == domain)
shared.set(false, forKey: "gptQuota")
shared.set(false, forKey: "codexResets")
SharedPreferences.migrate(domain: domain, shared: shared)
check("shared re-run preserves later GPT choice", shared.object(forKey: "gptQuota") as? Bool == false)
check("shared re-run preserves later resets choice", shared.object(forKey: "codexResets") as? Bool == false)
check("shared re-run preserves initial backup", ((shared.dictionary(forKey: "sharedSettingsBackupV1") ?? [:])[domain] as? [String: Any])?["gptQuota"] as? Bool == false)

// Every pet keeps its own explicit values, including original outfit and disabled.
let (_, first) = suite("first", ["size": 0.75, "outfitV1": "", "enabled": false, "origin": "{20,30}", "dock": "left"])
let (_, second) = suite("second")
let (_, third) = suite("third", ["skins": ["claude": "claude-pajamas"]])
SharedPreferences.migratePet(first, family: "claude", shared: shared)
SharedPreferences.migratePet(second, family: "claude", shared: shared)
SharedPreferences.migratePet(third, family: "claude", shared: shared)
check("explicit pet size retained", first.double(forKey: "size") == 0.75)
check("explicit empty outfit retained", first.string(forKey: "outfitV1") == "")
check("explicit disabled retained", first.object(forKey: "enabled") as? Bool == false)
check("position retained", first.string(forKey: "origin") == "{20,30}")
check("dock retained", first.string(forKey: "dock") == "left")
check("missing size copied from shared", second.double(forKey: "size") == 1.2)
check("missing outfit copied from shared", second.string(forKey: "outfitV1") == "claude-hoodie")
check("legacy per-pet outfit wins over shared", third.string(forKey: "outfitV1") == "claude-pajamas")
let petSources = first.dictionary(forKey: "clientSettingsSourcesV1") as? [String: String] ?? [:]
check("records existing pet size source", petSources["size"] == "pet")
check("records existing empty outfit source", petSources["outfitV1"] == "pet")
let copiedSources = second.dictionary(forKey: "clientSettingsSourcesV1") as? [String: String] ?? [:]
check("records copied shared size source", copiedSources["size"] == "shared")
check("records copied shared outfit source", copiedSources["outfitV1"] == "shared")
check("pet backup retains explicit empty outfit", first.dictionary(forKey: "clientSettingsBackupV1")?["outfitV1"] as? String == "")
check("pet backup retains explicit disabled", first.dictionary(forKey: "clientSettingsBackupV1")?["enabled"] as? Bool == false)
first.set(1.45, forKey: "size"); first.set("claude-pajamas", forKey: "outfitV1")
check("first pet changes do not change second size", second.double(forKey: "size") == 1.2)
check("first pet changes do not change second outfit", second.string(forKey: "outfitV1") == "claude-hoodie")
check("first pet changes do not change shared size", shared.double(forKey: "size") == 1.2)
check("first pet changes do not change shared outfit", (shared.dictionary(forKey: "skins") as? [String: String])?["claude"] == "claude-hoodie")
shared.set(2.0, forKey: "size"); shared.set(["claude": ""], forKey: "skins")
SharedPreferences.migratePet(first, family: "claude", shared: shared)
SharedPreferences.migratePet(second, family: "claude", shared: shared)
check("pet re-run preserves new user size", first.double(forKey: "size") == 1.45)
check("pet re-run preserves new user outfit", first.string(forKey: "outfitV1") == "claude-pajamas")
check("shared changes do not overwrite migrated size", second.double(forKey: "size") == 1.2)
check("shared changes do not overwrite migrated outfit", second.string(forKey: "outfitV1") == "claude-hoodie")
check("pet re-run preserves original backup", first.dictionary(forKey: "clientSettingsBackupV1")?["size"] as? Double == 0.75)

let result: [String: Any] = ["passed": passed, "failed": failed.count, "failures": failed]
let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
if !failed.isEmpty { exit(1) }
SWIFT
swiftc app/mac/SharedPreferences.swift "$scratch/main.swift" -o "$scratch/client-preferences-probe"
CFFIXED_USER_HOME="$scratch/home" "$scratch/client-preferences-probe"

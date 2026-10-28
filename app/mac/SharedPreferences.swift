import Foundation

/// Versioned, deterministic migration. Never infer a choice from a boolean's value.
enum SharedPreferences {
    static let keys = ["hidden", "textSize", "textLinked", "showName", "eggs", "hideFullscreen", "auraMode", "layer", "names", "edgeDock", "powerSave", "peakSkins", "peakStyle", "dsQuota", "gptQuota", "agyQuota", "codexResets", "quotaAggregate", "appearanceMode", "followApps", "followEvents", "hideHotkey", "whatsNewSeen"]
    static let sources = ["codex-desktop", "claude-desktop", "codex-tui", "claude-tui", "dsh-desktop", "gpt", "claude", "deepseek"]
    static func migrate(domain: String, shared: UserDefaults) {
        guard shared.integer(forKey: "sharedSettingsSchema") < 1 else { return }
        let legacy = sources.map { ("\(domain).pet.\($0)", shared.persistentDomain(forName: "\(domain).pet.\($0)") ?? [:]) }
        let original = shared.persistentDomain(forName: domain) ?? [:]
        // Snapshot BEFORE any write, including the old root values. Old suites stay untouched.
        if shared.dictionary(forKey: "sharedSettingsBackupV1") == nil {
            var backup: [String: Any] = [domain: original]
            for (name, values) in legacy { backup[name] = values }
            shared.set(backup, forKey: "sharedSettingsBackupV1")
            shared.synchronize()
        }
        var provenance: [String: String] = [:]
        for key in keys {
            if let (name, values) = legacy.first(where: { $0.1[key] != nil }) {
                shared.set(values[key], forKey: key); provenance[key] = name
            } else if original[key] != nil { provenance[key] = domain }
        }
        shared.set(provenance, forKey: "sharedSettingsSourcesV1")
        shared.set(1, forKey: "sharedSettingsSchema")
        shared.synchronize()
    }
    static func migratePet(_ pet: UserDefaults, family: String, shared: UserDefaults) {
        guard pet.integer(forKey: "clientSettingsSchema") < 1 else { return }
        // Preserve explicit false and original outfit (empty string); retain every legacy key.
        var backup: [String: Any] = [:]
        for key in ["size", "outfitV1", "skins", "enabled", "origin", "dock"] { if let value = pet.object(forKey: key) { backup[key] = value } }
        pet.set(backup, forKey: "clientSettingsBackupV1")
        var sources: [String: String] = [:]
        if pet.object(forKey: "size") == nil {
            pet.set(shared.object(forKey: "size") ?? 1.0, forKey: "size"); sources["size"] = "shared"
        } else { sources["size"] = "pet" }
        if pet.object(forKey: "outfitV1") == nil {
            let legacy = pet.dictionary(forKey: "skins") as? [String: String] ?? [:]
            let current = shared.dictionary(forKey: "skins") as? [String: String] ?? [:]
            pet.set(legacy[family] ?? current[family] ?? "", forKey: "outfitV1")
            sources["outfitV1"] = legacy[family] != nil ? "legacy-pet" : "shared"
        } else { sources["outfitV1"] = "pet" }
        if pet.object(forKey: "appearanceMode") == nil, let mode = shared.string(forKey: "appearanceMode") { pet.set(mode, forKey: "appearanceMode") }
        pet.set(sources, forKey: "clientSettingsSourcesV1")
        pet.set(1, forKey: "clientSettingsSchema")
    }

}

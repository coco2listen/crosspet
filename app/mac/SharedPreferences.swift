import Foundation

/// Versioned, deterministic migration. Never infer a choice from a boolean's value.
enum SharedPreferences {
    static let keys = ["hidden", "size", "textSize", "textLinked", "showName", "eggs", "hideFullscreen", "auraMode", "layer", "skins", "names", "edgeDock", "powerSave", "peakSkins", "peakStyle", "dsQuota", "gptQuota", "agyQuota", "codexResets", "quotaAggregate", "appearanceMode", "followApps", "followEvents", "hideHotkey", "whatsNewSeen"]
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
}

import Cocoa

extension App {
    var appearanceMode: String { windowDefaults.string(forKey: "appearanceMode").flatMap { AppearancePolicy.modes.contains($0) ? $0 : nil } ?? "onWork" }
    var appearanceMaster: Bool { appPreferences.object(forKey: "appearanceEnabled") as? Bool ?? true }
    func refreshAppearance(hosts supplied: [String: Double]? = nil) {
        guard owner === self else { owner.refreshAppearance(hosts: supplied); return }
        guard familiesMode else { return }
        let needsHosts = appearanceMaster && allPets.contains { $0.activeInMode && $0.appearanceMode == "followApp" }
        guard let hosts = supplied ?? (needsHosts ? AppearancePolicy.scan() : [:]) else { return }
        for pet in allPets {
            let result = pet.familyState?.aggregate()
            let state: [String: Any] = ["payload": result?.payload ?? [:], "count": result?.count ?? 0,
                "status": result?.status ?? "Unknown", "event": result?.event ?? "NoSessions", "ts": result?.ts ?? 0]
            let input: [String: Any] = ["mode": pet.appearanceMode, "master": appearanceMaster,
                "hostStarted": pet.petId.flatMap { hosts[$0] } as Any? ?? NSNull(),
                "state": state, "now": Date().timeIntervalSince1970]
            guard let visible = ClientPolicyBridge.call("visible", [input]) as? Bool else { continue }
            if pet.hiddenForAppearance == visible { pet.hiddenForAppearance = !visible; pet.applyHiddenState() }
        }
    }
    func saveAppearanceConfiguration() {
        if owner !== self { owner.saveAppearanceConfiguration(); return }
        // Remove only the obsolete watcher from our previous builds. Existing AI hook startup stays intact.
        if !isolatedRun {
            let label = "io.github.crosspet.appearance"
            let agent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
            if FileManager.default.fileExists(atPath: agent.path),
               let data = try? Data(contentsOf: agent),
               let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
               plist["Label"] as? String == label {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
                do { _ = try FileManager.default.trashItem(at: agent, resultingItemURL: nil) }
                catch { appearanceNote = "旧出现监视器未移除：\(error.localizedDescription)" }
            }
        }
        refreshAppearance()
    }
}

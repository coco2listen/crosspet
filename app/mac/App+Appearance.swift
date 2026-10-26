import Cocoa

extension App {
    var appearanceMode: String { defaults.string(forKey: "appearanceMode").flatMap { AppearancePolicy.modes.contains($0) ? $0 : nil } ?? "onWork" }
    var appearanceMaster: Bool { appPreferences.object(forKey: "appearanceEnabled") as? Bool ?? true }
    var appearanceConfig: URL { root.appendingPathComponent("appearance.json") }

    func appearanceHostStarted(_ hosts: [String: Double]) -> Double? {
        if let client, client == "tui" || client == "desktop" { return hosts[petId ?? ""] }
        let ids = family == "claude" ? ["claude-tui", "claude-desktop"] : family == "gpt" ? ["codex-tui", "codex-desktop"] : family == "deepseek" ? ["dsh-desktop"] : AppearancePolicy.ids
        return ids.compactMap { hosts[$0] }.max()
    }

    func refreshAppearance(hosts supplied: [String: Double]? = nil) {
        guard owner === self else { owner.refreshAppearance(hosts: supplied); return }
        let needsHosts = appearanceMaster && allPets.contains { $0.activeInMode && $0.appearanceMode == "followApp" }
        // Failed scans never count as process exits.
        guard let hosts = supplied ?? (needsHosts ? AppearancePolicy.scan() : [:]) else { return }
        for pet in allPets {
            let visible = AppearancePolicy.visible(mode: pet.appearanceMode, master: appearanceMaster, hostStarted: pet.appearanceHostStarted(hosts))
            if pet.hiddenForAppearance == visible {
                pet.hiddenForAppearance = !visible
                pet.applyHiddenState()
            }
        }
    }

    func saveAppearanceConfiguration() {
        guard owner === self else { owner.saveAppearanceConfiguration(); return }
        var pets: [[String: Any]] = []
        let specs = petMode == "clients" ? Self.petSpecs : petMode == "families" ? Self.familySpecs : []
        for spec in specs {
            let prefs = UserDefaults(suiteName: "\(preferenceDomain).pet.\(spec.id)")!
            let mode = appearanceMode
            pets.append(["id": spec.id, "mode": mode, "enabled": prefs.object(forKey: "enabled") as? Bool ?? true])
        }
        if petMode == "single" { pets = [["id": "single", "mode": appearanceMode, "enabled": true]] }
        let config: [String: Any] = ["master": appearanceMaster, "pets": pets]
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            try data.write(to: appearanceConfig, options: .atomic)
            if !isolatedRun {
                try configureAppearanceWatcher(needed: false)
            }
            appearanceNote = ""
        } catch { appearanceNote = "出现方式未能保存：\(error.localizedDescription)" }
        refreshAppearance()
    }

    /// No background job for default onWork; install only for opt-in host/always modes.
    func configureAppearanceWatcher(needed: Bool) throws {
        let label = "io.github.crosspet.appearance"
        let agent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let domain = "gui/\(getuid())"
        func launchctl(_ args: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
        }
        if !needed {
            if FileManager.default.fileExists(atPath: agent.path) {
                _ = launchctl(["bootout", domain + "/" + label]); try FileManager.default.removeItem(at: agent)
            }
            return
        }
        guard let binary = Bundle.main.executableURL else { return }
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [binary.path, "--appearance-watch"], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let changed = (try? Data(contentsOf: agent)) != data
        if changed {
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = launchctl(["bootout", domain + "/" + label])
            try data.write(to: agent, options: .atomic)
        }
        if changed || launchctl(["print", domain + "/" + label]) != 0 {
            guard launchctl(["bootstrap", domain, agent.path]) == 0 else { throw NSError(domain: label, code: 1, userInfo: [NSLocalizedDescriptionKey: "无法启动宿主监视器"]) }
        }
    }
}

func runAppearanceWatcher() -> Never {
    let env = ProcessInfo.processInfo.environment
    let root = env["CROSSPET_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CrossPet")
    let state = env["CROSSPET_STATE_DIR"] ?? "/tmp/crosspet"
    let appURL = Bundle.main.bundleURL
    var lastOpen = Date.distantPast
    func tick() {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("appearance.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = AppearancePolicy.scan() else { return }
        let quitAt = (try? root.appendingPathComponent("user-quit").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
        guard AppearancePolicy.shouldLaunch(config: config, hosts: hosts, quitAt: quitAt, bootAt: Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime),
              Date().timeIntervalSince(lastOpen) > 10 else { return }
        let pidText = try? String(contentsOfFile: state + "/pet.pid", encoding: .utf8)
        let pid = pidText.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let running = pid.flatMap { NSRunningApplication(processIdentifier: $0) }?.executableURL == Bundle.main.executableURL
        if !running {
            lastOpen = Date()
            let options = NSWorkspace.OpenConfiguration(); options.activates = false; options.createsNewApplicationInstance = true
            options.environment = env
            NSWorkspace.shared.openApplication(at: appURL, configuration: options)
        }
    }
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in tick() }
    }
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in tick() }
    tick(); RunLoop.main.run(); exit(0)
}

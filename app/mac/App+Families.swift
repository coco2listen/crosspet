import Cocoa
import WebKit

extension App {
    var owner: App { coordinator ?? self }
    var allPets: [App] { ([owner] + owner.familyPets).filter { $0.panel != nil } }
    var activePets: [App] { allPets.filter { $0.activeInMode } }
    var menuPet: App { activePets.first ?? owner.familyPets.first ?? owner }

    /// Five independent client pets. `family` selects the character and the producer directory; `client` the proven origin.
    static let petSpecs: [(id: String, family: String, client: String?, title: String)] = [
        ("claude-tui", "claude", "tui", "Claude 娘 · 终端"), ("claude-desktop", "claude", "desktop", "Claude 娘 · 桌面"),
        ("codex-tui", "gpt", "tui", "GPT 白龙娘 · 终端"), ("codex-desktop", "gpt", "desktop", "GPT 白龙娘 · 桌面"),
        ("dsh-desktop", "deepseek", "desktop", "DeepSeek 娘 · 桌面")]
    static let familySpecs: [(id: String, family: String, client: String?, title: String)] = [
        ("deepseek", "deepseek", nil, "DeepSeek"), ("gpt", "gpt", nil, "GPT"), ("claude", "claude", nil, "Claude")]
    static var petIds: [String] { petSpecs.map(\.id) }
    /// Default window position: step left from the right edge, one slot per pet.
    static func slot(of id: String?) -> Int {
        (familySpecs + petSpecs).firstIndex { $0.id == id }.map { $0 < familySpecs.count ? $0 : $0 - familySpecs.count } ?? 0
    }

    func setupFamilyPets() {
        migrateSeen()
        // No preference rewrite on upgrade: the original single-pet settings remain reversible.
        if defaults.object(forKey: "petMode") == nil {
            defaults.set(defaults.object(forKey: "character") == nil ? "families" : "single", forKey: "petMode")
        }
        applyPetMode()
    }

    /// Windows of both group modes are created once and then shown or hidden, so switching modes never loses a pet's state.
    func createFamilyWindows() {
        let missing = (Self.familySpecs + Self.petSpecs).filter { spec in
            (petMode == "clients") == (spec.client != nil) && !familyPets.contains { $0.petId == spec.id }
        }
        for spec in missing {
            let pet = App(family: spec.family, client: spec.client, petId: spec.id)
            pet.coordinator = self
            pet.latestRelease = latestRelease
            familyPets.append(pet)
            pet.createPetWindow()
            pet.userHidden = pet.defaults.bool(forKey: "hidden")
        }
    }

    func applyPetMode() {
        if familiesMode { owner.createFamilyWindows() }
        else if owner.panel == nil { owner.createPetWindow() }
        for pet in allPets {
            pet.activeInMode = pet.family == nil ? !familiesMode : (pet.client != nil) == (petMode == "clients") && familiesMode && (pet.defaults.object(forKey: "enabled") as? Bool ?? true)
            pet.applyHiddenState()
            if pet.activeInMode { pet.panel.orderFrontRegardless(); pet.stamps = [:] }
            else { pet.panel.orderOut(nil) }
        }
    }

    @objc func changePetMode(_ sender: NSMenuItem) {
        appPreferences.set(sender.representedObject as? String ?? "single", forKey: "petMode")
        owner.applyPetMode()
        owner.saveAppearanceConfiguration()
    }

    @objc func togglePetEnabled() {
        guard family != nil else { return }
        defaults.set(!(defaults.object(forKey: "enabled") as? Bool ?? true), forKey: "enabled")
        owner.applyPetMode()
        owner.saveAppearanceConfiguration()
    }

    @objc func toggleClientPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, Self.petIds.contains(id),
              let preferences = UserDefaults(suiteName: "\(preferenceDomain).pet.\(id)") else { return }
        preferences.set(!(preferences.object(forKey: "enabled") as? Bool ?? true), forKey: "enabled")
        appPreferences.set("clients", forKey: "petMode")
        owner.applyPetMode()
        owner.saveAppearanceConfiguration()
    }

    @objc func setPetSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        defaults.set(value, forKey: "size")
        applySizes(animateTo: CGFloat(value))
    }

    func addFamilyMenu(to menu: NSMenu) {
        let petsItem = NSMenuItem(title: "桌宠", action: nil, keyEquivalent: "")
        let pets = NSMenu()
        for spec in Self.petSpecs {
            let item = owner.add(pets, spec.title, #selector(toggleClientPet(_:)))
            item.representedObject = spec.id
            let preferences = UserDefaults(suiteName: "\(preferenceDomain).pet.\(spec.id)")!
            item.state = (preferences.object(forKey: "enabled") as? Bool ?? true) ? .on : .off
        }
        petsItem.submenu = pets; menu.addItem(petsItem)
        let single = owner.add(menu, "原有单桌宠", #selector(changePetMode(_:)))
        single.representedObject = "single"
        single.state = petMode == "single" ? .on : .off
        let size = NSMenuItem(title: "当前桌宠大小", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for value in [0.6, 0.8, 1.0, 1.2, 1.4, 1.6] {
            let item = add(sizes, "\(Int(value * 100))%", #selector(setPetSize(_:)))
            item.representedObject = value
            item.state = abs(Double(petScale) - value) < 0.01 ? .on : .off
        }
        size.submenu = sizes; menu.addItem(size)
        menu.addItem(.separator())
    }

    func appendRenderEvidence(_ row: [String: Any], to path: String) {
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) { try? Data().write(to: url, options: .atomic) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }

    func pollFamilyStates() {
        guard !pauseRealEvents, let family, let state = familyState else { return }
        let dir = stateDir.appendingPathComponent("families/\(family)", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where file.pathExtension == "json" {
            guard let stamp = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  stamp != stamps[file.path], let data = try? Data(contentsOf: file) else { continue }
            // Retry malformed/incomplete files; producers normally use atomic rename.
            if state.ingest(data) {
                stamps[file.path] = stamp
                if family == "gpt", let snapshot = try? JSONDecoder().decode(FamilySnapshot.self, from: data) {
                    if ["Stop", "AfterAgent", "turn/end"].contains(snapshot.event) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshCodexQuota(.turnEnd) }
                    }
                }
            }
        }
        for (key, record) in state.records {
            if let pid = record.pid, pid > 1, let producer = record.producerId,
               kill(pid, 0) != 0, errno == ESRCH {
                state.markProcessExited(key: key, producerId: producer)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: state.sessions(), options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8), text != familySessionPayload {
            familySessionPayload = text
            js("setSessions(\(quote(family)), \(text))")
        }
        let aggregate = state.aggregate()
        if family == "gpt" {
            codexBusyAt = state.records.values.filter { ["Thinking", "Tool Running", "Waiting Input", "Waiting Permission"].contains($0.status) }
                .map { Date(timeIntervalSince1970: $0.observedAt) }.max()
        }
        if let data = try? JSONSerialization.data(withJSONObject: aggregate.payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8), text != familyPayload {
            familyPayload = text
            lastPose[family] = (aggregate.pose, Date(timeIntervalSince1970: aggregate.ts))
            if isolatedRun, let trace = ProcessInfo.processInfo.environment["CROSSPET_RENDER_TRACE"], trace.hasPrefix("/") {
                let code = "applyFamilyState(\(quote(family)), \(text)); JSON.stringify({charId, renderedPose:pose, badge:document.getElementById('familyStatus')?.textContent})"
                web.evaluateJavaScript(code) { [weak self] result, error in
                    guard let self else { return }
                    var row = aggregate.payload
                    row["family"] = family; row["pet"] = self.petId ?? family; row["displayAt"] = Date().timeIntervalSince1970
                    if let result = result as? String, let data = result.data(using: .utf8),
                       let view = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        row.merge(view) { _, new in new }
                    }
                    if let error { row["error"] = error.localizedDescription }
                    // Opt-in test evidence contains state metadata only, never client payloads.
                    row.removeValue(forKey: "sessionId")
                    self.appendRenderEvidence(row, to: trace)
                    if aggregate.payload["lastResult"] != nil, ["Offline", "Idle"].contains(aggregate.status) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            self?.web.evaluateJavaScript("JSON.stringify({charId,renderedPose:pose,badge:document.getElementById('familyStatus')?.textContent})") { view, _ in
                                guard let self, let view = view as? String, let data = view.data(using: .utf8),
                                      var evidence = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                                evidence["family"] = family; evidence["kind"] = "result-animation-after-dwell"
                                evidence["displayAt"] = Date().timeIntervalSince1970
                                self.appendRenderEvidence(evidence, to: trace)
                            }
                        }
                    }
                }
            } else { js("applyFamilyState(\(quote(family)), \(text))") }
        }
        // Quotas keep their original source-specific paths; never consume legacy state here.
        for id in characterIds where quotaAggregate || id == family {
            guard !(id == "deepseek" && !dsQuotaEnabled) else { continue }
            let file = stateDir.appendingPathComponent("\(id)-quota.json")
            guard let stamp = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  stamp != stamps[file.path], let data = try? Data(contentsOf: file),
                  (try? JSONSerialization.jsonObject(with: data)) != nil, let text = String(data: data, encoding: .utf8) else { continue }
            stamps[file.path] = stamp
            js("setQuota(\(quote(id)), \(text))")
        }
    }
}

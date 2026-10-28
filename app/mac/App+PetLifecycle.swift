import Cocoa

extension App {
    /// Retain the view until the renderer optimization change; inactive windows never receive polling.
    func releasePetWindow() { panel?.orderOut(nil) }
}

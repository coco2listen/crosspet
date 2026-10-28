import Cocoa
import WebKit

extension App {
    /// Preferences and the lightweight controller survive; disabled pets own no rendering resources.
    func releasePetWindow() {
        guard let oldPanel = panel else { return }
        ready = false
        pendingSwitch?.cancel(); pendingSwitch = nil
        scaleTimer?.invalidate(); scaleTimer = nil
        if let oldWeb = web {
            oldWeb.navigationDelegate = nil
            oldWeb.stopLoading()
            oldWeb.configuration.userContentController.removeScriptMessageHandler(forName: "pet")
            oldWeb.removeFromSuperview()
        }
        oldPanel.orderOut(nil)
        oldPanel.contentView = nil
        // NSPanel is strongly owned here; closing must not also release it through AppKit.
        oldPanel.isReleasedWhenClosed = false
        oldPanel.close()
        web = nil; panel = nil
        fullscreenOverride = false; fullscreenCheckedAt = .distantPast
        hiddenForFullscreen = false
        shownScale = 0; shownFootPt = 0
        hitRects = []; hitRectsAt = .distantPast
        dock = nil; dockTucked = false; dockOut = false; dockHover = false
        dockEnterAt = nil; dockLeaveAt = nil; dockCut = [:]
        stamps = [:]; familyPayload = ""; familySessionPayload = ""; clientQuotaPayloads = [:]
    }
}

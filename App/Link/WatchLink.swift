import Foundation
import WatchConnectivity

/// Phone side of the watch link. The watch is optional; everything works without it.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Commands from the watch: "start-run", "start-walk", "stop", "capture".
    var onCommand: (@MainActor (String) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var isWatchAppInstalled: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isWatchAppInstalled
    }

    /// Latest state for the watch face. Uses application context so it survives the watch app being closed.
    func push(_ state: [String: Any]) {
        guard isWatchAppInstalled else { return }
        try? WCSession.default.updateApplicationContext(state)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(state, replyHandler: nil, errorHandler: nil)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmd = message["cmd"] as? String else { return }
        Task { @MainActor in self.onCommand?(cmd) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(["ok": true])
        guard let cmd = message["cmd"] as? String else { return }
        Task { @MainActor in self.onCommand?(cmd) }
    }
}

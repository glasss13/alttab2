import AppKit
import ApplicationServices
import WindowBridge

enum WindowAction { case quit, close, minimize, fullscreen }

final class FocusController {
    private let frontQueue = DispatchQueue(label: "local.alttab2.focus", qos: .userInteractive)
    private let verificationQueue = DispatchQueue(label: "local.alttab2.verify", qos: .userInitiated)
    private let actions: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        queue.name = "local.alttab2.actions"
        return queue
    }()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var latest: WindowRecord?
    private var requestedAt: Double = 0
    var onVerified: ((WindowID, Bool) -> Void)?
    var onAction: ((pid_t) -> Void)?

    func focus(_ record: WindowRecord) {
        lock.lock()
        generation &+= 1
        let token = generation
        latest = record
        requestedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        frontQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            if record.windowless {
                guard let url = record.appURL else { return }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            } else if record.minimized, let element = record.element {
                self.actions.addOperation {
                    guard self.isCurrent(token) else { return }
                    AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    self.frontQueue.async { self.front(record, token: token) }
                }
                return
            } else {
                self.front(record, token: token)
            }
        }
    }

    private func front(_ record: WindowRecord, token: UInt64) {
        guard isCurrent(token) else { return }
        if !ATFocusWindow(record.id.pid, record.id.window) {
            NSRunningApplication(processIdentifier: record.id.pid)?.activate(options: [])
        }
        verificationQueue.async { [weak self] in self?.verify(record, token: token, attempt: 0) }
        actions.addOperation { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            if let element = record.element { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
            if !self.isCurrent(token) {
                self.repairLatest()
                return
            }
        }
    }

    private func verify(_ record: WindowRecord, token: UInt64, attempt: Int) {
        guard isCurrent(token) else { return }
        let root = AXUIElementCreateApplication(record.id.pid)
        AXUIElementSetMessagingTimeout(root, 0.08)
        let wid = axElement(root, kAXFocusedWindowAttribute).map { ATWindowID($0) }
        let landed =
            NSWorkspace.shared.frontmostApplication?.processIdentifier == record.id.pid && wid == record.id.window
        let retryDelays = [0.008, 0.016, 0.032, 0.064, 0.128, 0.256, 0.4]
        if landed || attempt >= retryDelays.count {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                self.onVerified?(record.id, landed)
            }
        } else {
            verificationQueue.asyncAfter(deadline: .now() + retryDelays[attempt]) { [weak self] in
                self?.verify(record, token: token, attempt: attempt + 1)
            }
        }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }

    private func repairLatest() {
        frontQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let record = self.latest
            let age = ProcessInfo.processInfo.systemUptime - self.requestedAt
            self.lock.unlock()
            if let record, !record.windowless, age < 0.8 { _ = ATFocusWindow(record.id.pid, record.id.window) }
        }
    }

    func act(_ action: WindowAction, on record: WindowRecord) {
        actions.addOperation { [weak self] in
            if action == .quit {
                if record.bundleID != "com.apple.finder" {
                    NSRunningApplication(processIdentifier: record.id.pid)?.terminate()
                }
            } else if let element = record.element {
                switch action {
                case .close:
                    if let close = axElement(element, kAXCloseButtonAttribute) {
                        AXUIElementPerformAction(close, kAXPressAction as CFString)
                    }
                case .minimize:
                    AXUIElementSetAttributeValue(
                        element, kAXMinimizedAttribute as CFString, record.minimized ? kCFBooleanFalse : kCFBooleanTrue)
                case .fullscreen:
                    AXUIElementSetAttributeValue(
                        element, "AXFullScreen" as CFString, record.fullscreen ? kCFBooleanFalse : kCFBooleanTrue)
                case .quit: break
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.onAction?(record.id.pid) }
        }
    }
}

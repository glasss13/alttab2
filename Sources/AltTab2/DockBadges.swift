import AppKit
import ApplicationServices

/// Main-thread cache; Dock accessibility calls run on a separate serial queue.
final class DockBadges {
    private let worker = DispatchQueue(label: "local.alttab2.dock-badges", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var labels: [String: String] = [:]
    var onChange: (([String: String]) -> Void)?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.4
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        worker.async { [weak self] in
            let next = Self.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard let next, next != self.labels else { return }
                self.labels = next
                self.onChange?(next)
            }
        }
    }

    private static func read() -> [String: String]? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        guard let children = axValue(root, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        var labels: [String: String] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var foundList = false
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.1)
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard axValue(child, kAXRoleAttribute) as? String == kAXListRole else { continue }
            guard let items = axValue(child, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            foundList = true
            for item in items {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                AXUIElementSetMessagingTimeout(item, 0.1)
                var raw: CFArray?
                // AXStatusLabel is the Dock's badge text, including labels such as "99+".
                let result = AXUIElementCopyMultipleAttributeValues(
                    item, [kAXSubroleAttribute, kAXURLAttribute, "AXStatusLabel"] as CFArray, [], &raw)
                guard result == .success, let values = raw as? [Any], values.count == 3 else { return nil }
                guard values[0] as? String == kAXApplicationDockItemSubrole,
                    let url = values[1] as? URL,
                    let label = values[2] as? String
                else { continue }
                let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && text != "0" { labels[url.standardizedFileURL.path] = text }
            }
        }
        // Preserve the last snapshot while the Dock is unavailable or restarting.
        return foundList ? labels : nil
    }
}

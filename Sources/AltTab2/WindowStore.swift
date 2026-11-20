import AppKit
import ApplicationServices
import WindowBridge

func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = axValue(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

struct WindowRecord {
    let id: WindowID
    var title: String
    let appName: String
    let bundleID: String
    let appURL: URL?
    var frame: CGRect
    var minimized: Bool
    var fullscreen: Bool
    var hidden: Bool
    var element: AXUIElement?
    var icon: NSImage?
    var windowless: Bool { id.window == 0 }
}

enum RemovalTarget: Hashable {
    case window(WindowID)
    case app(pid_t)

    var pid: pid_t {
        switch self {
        case .window(let id): return id.pid
        case .app(let pid): return pid
        }
    }
}

private struct AppSnapshot {
    let pid: pid_t
    let windows: [WindowRecord]
    let focused: WindowID?
    let icon: NSImage?
    let successful: Bool
}

/// Owned by main. AX operations are bounded, per-process coalesced, and never awaited by input.
final class WindowStore {
    private(set) var records: [WindowID: WindowRecord] = [:]
    private(set) var recent = RecentWindows()
    private(set) var ready = false
    var onChange: (() -> Void)?
    var onFocus: ((WindowID) -> Void)?
    private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.alttab2.discovery"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()
    private var inFlight = Set<pid_t>()
    private var dirty = Set<pid_t>()
    private var generations: [pid_t: UInt64] = [:]
    private var apps: [pid_t: NSRunningApplication] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var reconcileWork: DispatchWorkItem?
    private var orderCheck: DispatchSourceTimer?
    private var initialPending = Set<pid_t>()
    private var missingSince: [WindowID: Double] = [:]
    private var expectedRemovals: [RemovalTarget: UUID] = [:]
    private lazy var observers = AXObservers { [weak self] pid in
        DispatchQueue.main.async { self?.refresh(pid) }
    }

    var ordered: [WindowID] {
        let valid = recent.order(at: ProcessInfo.processInfo.systemUptime).filter { records[$0]?.hidden == false }
        return valid.filter { records[$0]?.windowless == false } + valid.filter { records[$0]?.windowless == true }
    }
    var current: WindowID? { recent.order(at: ProcessInfo.processInfo.systemUptime).first }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
        ] {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.scheduleReconcile()
                })
        }
        tokens.append(
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                [weak self] _ in
                // AppKit publishes incomplete window lists while a Space animation is running.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self?.reconcile() }
            })
        tokens.append(
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
                [weak self] event in
                guard let self, let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                self.refresh(app.processIdentifier)
            })
        // Some apps silently order out a window without destroying its AX element.
        // Check the inexpensive window order off-main; only reread affected apps.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            guard let ids = ATCopyOrderedWindowIDs() as? [UInt32] else { return }
            let ordered = Set(ids)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let missing = self.records.values.filter {
                    !$0.windowless && !$0.hidden && !$0.minimized && !ordered.contains($0.id.window)
                }
                for pid in Set(missing.map { $0.id.pid }) { self.refresh(pid) }
            }
        }
        orderCheck = timer
        timer.resume()
        reconcile()
    }

    func scheduleReconcile() {
        guard reconcileWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.reconcileWork = nil
            self?.reconcile()
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func reconcile() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }
        let live = Set(running.map(\.processIdentifier))
        for pid in Set(apps.keys).subtracting(live) {
            expectedRemovals[.app(pid)] = nil
            apps[pid] = nil
            generations[pid, default: 0] += 1
            records = records.filter { $0.key.pid != pid }
            observers.remove(pid)
        }
        if !ready { initialPending.formUnion(live) }
        for app in running {
            apps[app.processIdentifier] = app
            refresh(app.processIdentifier)
        }
        synchronizeOrder()
        if running.isEmpty { ready = true }
    }

    func refresh(_ pid: pid_t) {
        guard let app = apps[pid], !app.isTerminated else {
            scheduleReconcile()
            return
        }
        guard !inFlight.contains(pid) else {
            dirty.insert(pid)
            return
        }
        inFlight.insert(pid)
        let generation = generations[pid, default: 0]
        let previous = records.values.filter { $0.id.pid == pid && !$0.windowless }
        workers.addOperation { [weak self] in
            let snapshot = Self.read(app, previous: previous)
            DispatchQueue.main.async { self?.accept(snapshot, generation: generation) }
        }
    }

    func requestFocus(_ id: WindowID) {
        recent.request(id, at: ProcessInfo.processInfo.systemUptime)
    }

    func observeFocus(_ id: WindowID) {
        guard records[id] != nil else { return }
        recent.observe(id, at: ProcessInfo.processInfo.systemUptime)
        onFocus?(id)
        onChange?()
    }

    func rejectFocus() {
        recent.rejectPending()
        onChange?()
    }

    func visibleWindows(in order: [WindowID]) -> [WindowID] {
        guard !expectedRemovals.isEmpty else { return order }
        return order.filter { !expectsRemoval($0) }
    }

    private func expectsRemoval(_ id: WindowID) -> Bool {
        expectedRemovals[.window(id)] != nil || expectedRemovals[.app(id.pid)] != nil
    }

    // A successful AX press or termination request can still lead to a save dialog.
    func expectRemoval(_ target: RemovalTarget) -> (Bool) -> Void {
        let token = UUID()
        expectedRemovals[target] = token
        onChange?()
        let restore = { [weak self] in
            guard let self, self.expectedRemovals[target] == token else { return }
            self.expectedRemovals[target] = nil
            self.refresh(target.pid)
            self.onChange?()
        }
        return { accepted in
            if accepted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: restore)
            } else {
                restore()
            }
        }
    }

    private func accept(_ snapshot: AppSnapshot, generation: UInt64) {
        inFlight.remove(snapshot.pid)
        initialPending.remove(snapshot.pid)
        if initialPending.isEmpty { ready = true }
        guard apps[snapshot.pid] != nil, generations[snapshot.pid, default: 0] == generation else { return }
        if snapshot.successful {
            let incoming = Set(snapshot.windows.map(\.id))
            let now = ProcessInfo.processInfo.systemUptime
            var retry = false
            for old in records.values.filter({ $0.id.pid == snapshot.pid }) where !incoming.contains(old.id) {
                let since = missingSince[old.id] ?? now
                missingSince[old.id] = since
                if old.windowless || expectsRemoval(old.id) || now - since >= 0.8 {
                    records[old.id] = nil
                    missingSince[old.id] = nil
                    expectedRemovals[.window(old.id)] = nil
                } else {
                    retry = true
                }
            }
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in self?.refresh(snapshot.pid) }
            }
            for var window in snapshot.windows {
                missingSince[window.id] = nil
                if window.windowless && records.values.contains(where: { $0.id.pid == snapshot.pid && !$0.windowless })
                {
                    continue
                }
                window.icon = snapshot.icon
                records[window.id] = window
            }
            observers.watch(
                snapshot.pid, elements: records.values.filter { $0.id.pid == snapshot.pid }.compactMap(\.element))
        }
        synchronizeOrder()
        if let focused = snapshot.focused, NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid {
            observeFocus(focused)
        } else {
            onChange?()
        }
        if dirty.remove(snapshot.pid) != nil { refresh(snapshot.pid) }
    }

    private func synchronizeOrder() {
        recent.inventory(
            records.values.sorted { a, b in
                if a.windowless != b.windowless { return !a.windowless }
                if a.id.pid != b.id.pid { return a.id.pid < b.id.pid }
                return a.id.window < b.id.window
            }.map(\.id))
    }

    private static func read(_ app: NSRunningApplication, previous: [WindowRecord]) -> AppSnapshot {
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let name = app.localizedName ?? "Application"
        let bundle = app.bundleIdentifier ?? ""
        let icon = app.icon
        var raw: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            root,
            [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute] as CFArray, [], &raw)
        guard result == .success, let published = raw as? [Any], published.count == 3 else {
            return AppSnapshot(pid: pid, windows: [], focused: nil, icon: icon, successful: false)
        }
        let cgWindows = (ATCopyAllWindowInfo() as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        var elements = published[0] as? [AXUIElement] ?? []
        for value in published.dropFirst() {
            let ref = value as CFTypeRef
            if CFGetTypeID(ref) == AXUIElementGetTypeID() { elements.append(ref as! AXUIElement) }
        }
        // Apps can order a closed window out while keeping its ID and AX element alive.
        // An offscreen surface can still be a real window on another Space.
        let offscreen = cgWindows.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) != true }
        var liveIDs = Set(cgWindows.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        if !offscreen.isEmpty {
            let ordered = Set(ATCopyOrderedWindowIDs() as? [UInt32] ?? elements.map { ATWindowID($0) })
            let offscreenIDs = offscreen.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
            liveIDs.subtract(offscreenIDs.filter { !ordered.contains($0) })
        }
        elements += previous.filter { liveIDs.contains($0.id.window) || $0.minimized || app.isHidden }.compactMap(
            \.element)
        let known = Set(elements.map { ATWindowID($0) })
        let candidates = cgWindows.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0
                && !known.contains($0[kCGWindowNumber as String] as? UInt32 ?? 0)
        }
        let missing = candidates.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        if !missing.isEmpty, let resolved = ATCopyWindowElements(pid, missing as CFArray) as? [NSNumber: AXUIElement] {
            elements += resolved.values
        }
        var bounds: [UInt32: CGRect] = [:]
        for info in cgWindows {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                let rect = info[kCGWindowBounds as String] as? [String: Any],
                let frame = CGRect(dictionaryRepresentation: rect as CFDictionary)
            else { continue }
            bounds[id] = frame
        }
        let focusValue = published[1] as CFTypeRef
        let focusedID: UInt32? =
            CFGetTypeID(focusValue) == AXUIElementGetTypeID() ? ATWindowID((focusValue as! AXUIElement)) : nil
        var windows: [WindowRecord] = []
        var seen = Set<UInt32>()
        for element in elements {
            AXUIElementSetMessagingTimeout(element, 0.08)
            let wid = ATWindowID(element)
            guard wid != 0, seen.insert(wid).inserted else { continue }
            let names =
                [kAXTitleAttribute, kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen"]
                as CFArray
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names, [], &values)
            guard error == .success, let attrs = values as? [Any], attrs.count == 5 else {
                if let old = previous.first(where: { $0.id.window == wid }), liveIDs.contains(wid) {
                    windows.append(old)
                }
                continue
            }
            let role = attrs[1] as? String
            let subrole = attrs[2] as? String
            guard role == kAXWindowRole, subrole != kAXSystemDialogSubrole, subrole != kAXFloatingWindowSubrole else {
                continue
            }
            let minimized = attrs[3] as? Bool ?? false
            // Inactive native tabs can remain published AXWindows but have no physical
            // surface on any Space. Keep the drawn representative, plus minimized windows.
            guard liveIDs.contains(wid) || minimized || app.isHidden else { continue }
            let frame = bounds[wid] ?? .zero
            windows.append(
                WindowRecord(
                    id: WindowID(pid: pid, window: wid), title: attrs[0] as? String ?? name,
                    appName: name, bundleID: bundle, appURL: app.bundleURL, frame: frame,
                    minimized: minimized, fullscreen: attrs[4] as? Bool ?? false,
                    hidden: app.isHidden, element: element, icon: nil))
        }
        for old in previous where !seen.contains(old.id.window) && liveIDs.contains(old.id.window) {
            var retained = old
            retained.hidden = app.isHidden
            windows.append(retained)
        }
        if windows.isEmpty, elements.isEmpty, candidates.isEmpty, bundle != "com.apple.finder" {
            windows.append(
                WindowRecord(
                    id: WindowID(pid: pid, window: 0), title: name, appName: name,
                    bundleID: bundle, appURL: app.bundleURL, frame: .zero, minimized: false, fullscreen: false,
                    hidden: app.isHidden, element: nil, icon: nil))
        }
        let focused =
            focusedID.flatMap { wid in windows.first { $0.id.window == wid }?.id }
            ?? (windows.count == 1 && windows[0].windowless ? windows[0].id : nil)
        return AppSnapshot(pid: pid, windows: windows, focused: focused, icon: icon, successful: true)
    }
}

private final class AXObservers {
    private let callback: (pid_t) -> Void
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var queued: [() -> Void] = []
    private var entries: [pid_t: (AXObserver, [AXUIElement])] = [:]

    init(callback: @escaping (pid_t) -> Void) {
        self.callback = callback
        let worker = Thread { [weak self] in self?.run() }
        worker.name = "AltTab2 accessibility events"
        worker.qualityOfService = .utility
        worker.start()
    }

    private func run() {
        let current = CFRunLoopGetCurrent()!
        var context = CFRunLoopSourceContext()
        let keeper = CFRunLoopSourceCreate(nil, 0, &context)!
        CFRunLoopAddSource(current, keeper, .commonModes)
        lock.lock()
        loop = current
        let pending = queued
        queued = []
        lock.unlock()
        pending.forEach { $0() }
        CFRunLoopRun()
    }

    private func submit(_ body: @escaping () -> Void) {
        lock.lock()
        guard let loop else {
            queued.append(body)
            lock.unlock()
            return
        }
        lock.unlock()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, body)
        CFRunLoopWakeUp(loop)
    }

    func watch(_ pid: pid_t, elements: [AXUIElement]) {
        submit { [self] in
            if let entry = entries[pid] {
                for element in entry.1 where !elements.contains(where: { CFEqual($0, element) }) {
                    for name in [
                        kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                    ] {
                        AXObserverRemoveNotification(entry.0, element, name as CFString)
                    }
                }
            }
            var observer = entries[pid]?.0
            if observer == nil {
                AXObserverCreate(
                    pid,
                    { _, element, _, context in
                        guard let context else { return }
                        let hub = Unmanaged<AXObservers>.fromOpaque(context).takeUnretainedValue()
                        var pid: pid_t = 0
                        AXUIElementGetPid(element, &pid)
                        hub.callback(pid)
                    }, &observer)
                guard let observer else { return }
                CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
                let root = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root, 0.1)
                for name in [
                    kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification,
                    kAXApplicationShownNotification,
                ] {
                    AXObserverAddNotification(
                        observer, root, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                }
            }
            guard let observer else { return }
            let oldElements = entries[pid]?.1 ?? []
            for element in elements where !oldElements.contains(where: { CFEqual($0, element) }) {
                for name in [
                    kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
                    kAXWindowDeminiaturizedNotification,
                ] {
                    AXObserverAddNotification(
                        observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                }
            }
            entries[pid] = (observer, elements)
        }
    }

    func remove(_ pid: pid_t) {
        submit { [self] in
            if let entry = entries.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(entry.0), .commonModes)
            }
        }
    }
}

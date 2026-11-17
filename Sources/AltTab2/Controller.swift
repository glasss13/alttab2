import AppKit

final class Controller {
    let store = WindowStore()
    let thumbnails = Thumbnails()
    let keyboard = Keyboard()
    let focus = FocusController()
    let panel = SwitcherPanel()
    private var session = SwitchSession()
    private var cachedOrder: [WindowID] = []
    private var preparedOrder: [WindowID] = []
    private var preparedScreen: NSScreen?
    private var warmWork: DispatchWorkItem?
    private var sessionGeneration: UInt64 = 0
    private var started = false
    private var lastFocused: WindowID?
    var onInputFailure: (() -> Void)?

    func start() {
        guard !started else { return }
        started = true
        thumbnails.enabled = CGPreflightScreenCaptureAccess()
        store.onChange = { [weak self] in self?.changed() }
        store.onFocus = { [weak self] id in
            guard let self else { return }
            var capture: [WindowRecord] = []
            if let old = self.lastFocused, let record = self.store.records[old] { capture.append(record) }
            if let record = self.store.records[id] { capture.append(record) }
            self.lastFocused = id
            self.thumbnails.request(capture, force: true, priority: true)
        }
        thumbnails.onImage = { [weak self] id, image in
            guard self?.store.records[id] != nil else { return }
            self?.panel.updateImage(id, image)
        }
        thumbnails.onEviction = { [weak self] id in self?.panel.evictImage(id) }
        keyboard.onInput = { [weak self] action in self?.input(action) }
        keyboard.onFailure = { [weak self] in self?.onInputFailure?() }
        focus.onVerified = { [weak self] id, success in
            if success { self?.store.observeFocus(id) } else { self?.store.rejectFocus() }
        }
        focus.onAction = { [weak self] pid in self?.store.refresh(pid) }
        panel.onSelect = { [weak self] id in
            self?.session.select(id)
            self?.commit()
        }
        panel.onAction = { [weak self] action, id in
            guard let self else { return }
            self.session.select(id)
            self.panel.highlight(id)
            self.perform(action, on: id)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.preparedScreen = nil
            self?.scheduleWarm()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.cancel() }
        store.start()
        keyboard.start()
    }

    private func input(_ action: InputAction) {
        switch action {
        case .tab(let direction):
            if session.active {
                session.step(direction)
                panel.highlight(session.selected)
            } else {
                session.begin(cachedOrder, current: store.current)
                guard session.active else { return }
                if direction < 0 { session.step(-2) }
                sessionGeneration &+= 1
                let generation = sessionGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session.active, self.sessionGeneration == generation, self.keyboard.gestureHeld
                    else { return }
                    self.show()
                }
            }
        case .arrow(let code):
            guard session.active else { return }
            if code == 123 {
                session.step(-1)
            } else if code == 124 {
                session.step(1)
            } else {
                let grid = GridGeometry(count: session.items.count, columns: panel.columns)
                let index = grid.verticalNeighbor(of: session.selectedIndex, direction: code == 126 ? -1 : 1)
                session.select(session.items[index])
            }
            panel.highlight(session.selected)
        case .commit: commit(endKeyboardGesture: false)
        case .cancel: cancel(endKeyboardGesture: false)
        case .selectedAction(let action):
            guard session.active, let id = session.selected else { return }
            perform(action, on: id)
        }
    }

    private func perform(_ action: WindowAction, on id: WindowID) {
        guard let record = store.records[id] else { return }
        if action == .close { store.expectRemoval(id) }
        focus.act(action, on: record)
        if action == .fullscreen || action == .minimize {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.store.refresh(id.pid) }
        }
    }

    private func show() {
        if preparedOrder != session.items { prepare(session.items) }
        panel.present(selected: session.selected)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.active else { return }
            self.thumbnails.request(
                self.session.items.compactMap { self.store.records[$0] }, force: true, priority: true)
            self.store.scheduleReconcile()
        }
    }

    private func commit(endKeyboardGesture: Bool = true) {
        guard let id = session.end(), let record = store.records[id] else {
            cancel(endKeyboardGesture: endKeyboardGesture)
            return
        }
        sessionGeneration &+= 1
        // A release is already recorded by the tap. Clearing it here could erase a
        // newer held gesture whose events are queued behind this commit on main.
        if endKeyboardGesture { keyboard.cancel() }
        store.requestFocus(id)
        cachedOrder = store.ordered
        focus.focus(record)
        panel.dismiss()
        scheduleWarm()
    }

    private func cancel(endKeyboardGesture: Bool = true) {
        _ = session.end()
        sessionGeneration &+= 1
        if endKeyboardGesture { keyboard.cancel() }
        panel.dismiss()
        scheduleWarm()
    }

    private func changed() {
        cachedOrder = store.ordered
        thumbnails.retain(Set(store.records.keys))
        if session.active {
            session.reconcile(available: Set(cachedOrder))
            if !session.active {
                cancel()
                return
            }
        }
        scheduleWarm()
    }

    private func scheduleWarm() {
        guard warmWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.warmWork = nil
            let order = self.session.active ? self.session.items : self.cachedOrder
            self.prepare(order)
            if self.session.active {
                self.panel.highlight(self.session.selected)
            } else {
                self.thumbnails.request(order.compactMap { self.store.records[$0] })
            }
        }
        warmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func prepare(_ ids: [WindowID]) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        var screen = preparedScreen ?? primary
        if let current = store.current, let record = store.records[current], record.frame != .zero {
            let point = NSPoint(x: record.frame.midX, y: primary.frame.maxY - record.frame.midY)
            screen = screens.first { $0.frame.contains(point) } ?? screen
        }
        preparedScreen = screen
        panel.prepare(ids.compactMap { store.records[$0] }, screen: screen, thumbnail: { self.thumbnails.image($0) })
        preparedOrder = ids
    }

    func status() -> [String: Any] {
        [
            "ready": store.ready, "keyboard": keyboard.installed,
            "accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
            "windows": cachedOrder.count,
        ]
    }
}

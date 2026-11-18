import Foundation

struct WindowID: Hashable {
    let pid: Int32
    let window: UInt32
    init(pid: Int32, window: UInt32) {
        self.pid = pid
        self.window = window
    }
}

// Keep the order stable until Command is released.
struct SwitchSession {
    private var initialOrder: [WindowID] = []
    private(set) var items: [WindowID] = []
    private(set) var selectedIndex = 0
    private(set) var active = false
    var selected: WindowID? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    init() {}

    mutating func begin(_ order: [WindowID], visible: [WindowID], current: WindowID?) {
        initialOrder = order
        items = visible
        active = !items.isEmpty
        selectedIndex = 0
        if let current, let index = items.firstIndex(of: current), items.count > 1 {
            selectedIndex = (index + 1) % items.count
        }
    }

    mutating func step(_ delta: Int) {
        guard active, !items.isEmpty else { return }
        selectedIndex = ((selectedIndex + delta) % items.count + items.count) % items.count
    }

    mutating func select(_ id: WindowID) {
        if let index = items.firstIndex(of: id) { selectedIndex = index }
    }

    mutating func reconcile(available: Set<WindowID>) {
        let old = selected
        let oldIndex = selectedIndex
        items = initialOrder.filter { available.contains($0) }
        selectedIndex = old.flatMap { items.firstIndex(of: $0) } ?? min(oldIndex, max(0, items.count - 1))
        if items.isEmpty { active = false }
    }

    mutating func end() -> WindowID? {
        let result = active ? selected : nil
        active = false
        initialOrder = []
        items = []
        return result
    }
}

/// Confirmed MRU and an expiring speculative focus are separate: quick taps can alternate
/// before the OS answers, while a refused focus cannot permanently corrupt the ordering.
struct RecentWindows {
    private(set) var confirmed: [WindowID] = []
    private(set) var pending: WindowID?
    private var pendingOrder: [WindowID] = []
    private var pendingUntil: TimeInterval = 0
    init() {}

    func order(at now: TimeInterval) -> [WindowID] {
        pending != nil && now < pendingUntil ? pendingOrder : confirmed
    }

    mutating func inventory(_ ids: [WindowID]) {
        let valid = Set(ids)
        confirmed.removeAll { !valid.contains($0) }
        pendingOrder.removeAll { !valid.contains($0) }
        let existing = Set(confirmed)
        confirmed.append(contentsOf: ids.filter { !existing.contains($0) })
        let pendingExisting = Set(pendingOrder)
        pendingOrder.append(contentsOf: ids.filter { !pendingExisting.contains($0) })
        if let pending, !valid.contains(pending) { self.pending = nil }
    }

    mutating func request(_ id: WindowID, at now: TimeInterval) {
        var next = order(at: now)
        next.removeAll { $0 == id }
        next.insert(id, at: 0)
        pendingOrder = next
        pending = id
        pendingUntil = now + 0.8
    }

    mutating func observe(_ id: WindowID, at now: TimeInterval) {
        if let pending, pending != id, now < pendingUntil { return }
        if pending == id { confirmed = pendingOrder }
        pending = nil
        confirmed.removeAll { $0 == id }
        confirmed.insert(id, at: 0)
    }

    mutating func rejectPending() { pending = nil }
}

struct GridGeometry {
    let columns: Int
    let count: Int
    init(count: Int, columns: Int) {
        self.count = count
        self.columns = max(1, columns)
    }
    func verticalNeighbor(of index: Int, direction: Int) -> Int {
        guard count > 0 else { return 0 }
        let target = index + direction * columns
        if target < 0 || target >= count { return index }
        return target
    }
}

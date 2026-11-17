import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// All bookkeeping is main-owned. ScreenCaptureKit is asynchronous; slots are released
/// by completion, not by dispatching a request, so the OS sees at most two captures.
final class Thumbnails {
    private struct Entry {
        let image: CGImage
        let bytes: Int
        var used: Double
        let captured: Double
    }
    private var images: [WindowID: Entry] = [:]
    private var windows: [UInt32: SCWindow] = [:]
    private var pending: [WindowID] = []
    private var requested: [WindowID: WindowRecord] = [:]
    private var active = Set<WindowID>()
    private var lastDiscovery = -Double.infinity
    private var discovering = false
    private var failedAt: [WindowID: Double] = [:]
    private var liveIDs = Set<WindowID>()
    private var bytes = 0
    private let byteLimit = 96 * 1024 * 1024
    private let queue = DispatchQueue(label: "local.alttab2.capture", qos: .utility)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    var enabled = false
    var onImage: ((WindowID, CGImage) -> Void)?
    var onEviction: ((WindowID) -> Void)?

    func image(_ id: WindowID) -> CGImage? {
        guard var entry = images[id] else { return nil }
        entry.used = ProcessInfo.processInfo.systemUptime
        images[id] = entry
        return entry.image
    }

    func retain(_ ids: Set<WindowID>) {
        liveIDs = ids
        for id in Array(images.keys) where !ids.contains(id) {
            bytes -= images.removeValue(forKey: id)?.bytes ?? 0
        }
        pending.removeAll { !ids.contains($0) }
        requested = requested.filter { ids.contains($0.key) }
        failedAt = failedAt.filter { ids.contains($0.key) }
    }

    func request(_ records: [WindowRecord], force: Bool = false, priority: Bool = false) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var additions: [WindowID] = []
        for record in records where !record.windowless && !record.hidden {
            guard !active.contains(record.id), now - (failedAt[record.id] ?? -100) > 3 else { continue }
            if let entry = images[record.id], now - entry.captured < (force ? 0.8 : 20) { continue }
            if requested[record.id] == nil { additions.append(record.id) }
            requested[record.id] = record
        }
        if priority { pending.insert(contentsOf: additions, at: 0) } else { pending.append(contentsOf: additions) }
        if pending.count > 256 {
            for id in pending.dropFirst(256) { requested[id] = nil }
            pending = Array(pending.prefix(256))
        }
        pump()
    }

    private func discover() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !discovering, now - lastDiscovery > 2 else { return }
        discovering = true
        lastDiscovery = now
        queue.async {
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.discovering = false
                    if let content {
                        self.windows = Dictionary(
                            content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { _, new in new })
                    } else {
                        if !CGPreflightScreenCaptureAccess() { self.enabled = false }
                    }
                    self.pump()
                }
            }
        }
    }

    private func pump() {
        guard enabled else { return }
        var needsDiscovery = false
        while active.count < 2, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let record = requested[id] else { continue }
            guard let window = windows[id.window] else {
                needsDiscovery = true
                // Retain missing requests until the next discovery; don't spin on them.
                continue
            }
            requested[id] = nil
            active.insert(id)
            capture(record, window)
        }
        if !discovering && ProcessInfo.processInfo.systemUptime - lastDiscovery <= 2 {
            for id in Array(requested.keys) where windows[id.window] == nil {
                requested[id] = nil
                failedAt[id] = ProcessInfo.processInfo.systemUptime
            }
        }
        if needsDiscovery { discover() }
        if !discovering {
            let pendingSet = Set(pending)
            pending.append(
                contentsOf: requested.keys.filter {
                    windows[$0.window] != nil && !active.contains($0) && !pendingSet.contains($0)
                })
            if active.count < 2, !pending.isEmpty { pump() }
        }
    }

    private func capture(_ record: WindowRecord, _ window: SCWindow) {
        let id = record.id
        let size = window.frame.size
        let scale = min(1, 640 / max(1, size.width), 420 / max(1, size.height))
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        queue.async { [weak self] in
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let complete: (CGImage?) -> Void = { image in
                DispatchQueue.main.async { self?.finish(id, image: image) }
            }
            if record.fullscreen {
                // macOS 26's screenshot API can refuse fullscreen windows on inactive Spaces.
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.showsCursor = false
                SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) {
                    [weak self] sample, _ in
                    guard let self, let sample, let buffer = CMSampleBufferGetImageBuffer(sample) else {
                        complete(nil)
                        return
                    }
                    self.queue.async {
                        let source = CIImage(cvPixelBuffer: buffer)
                        complete(self.imageContext.createCGImage(source, from: source.extent))
                    }
                }
            } else {
                let config = SCScreenshotConfiguration()
                config.width = width
                config.height = height
                config.showsCursor = false
                config.dynamicRange = .sdr
                SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, _ in
                    complete(output?.sdrImage)
                }
            }
        }
    }

    private func finish(_ id: WindowID, image: CGImage?) {
        active.remove(id)
        guard liveIDs.contains(id) else {
            pump()
            return
        }
        if let image {
            let cost = image.bytesPerRow * image.height
            bytes -= images[id]?.bytes ?? 0
            let now = ProcessInfo.processInfo.systemUptime
            images[id] = Entry(image: image, bytes: cost, used: now, captured: now)
            bytes += cost
            while bytes > byteLimit, let oldest = images.min(by: { $0.value.used < $1.value.used })?.key {
                bytes -= images.removeValue(forKey: oldest)?.bytes ?? 0
                onEviction?(oldest)
            }
            if images[id] != nil { onImage?(id, image) }
        } else {
            failedAt[id] = ProcessInfo.processInfo.systemUptime
        }
        pump()
    }
}

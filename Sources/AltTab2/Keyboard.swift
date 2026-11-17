import AppKit

enum InputAction {
    case tab(Int)
    case arrow(Int)
    case selectedAction(WindowAction)
    case commit, cancel
}

// The event tap must never wait on AppKit or window discovery.
final class Keyboard {
    var onInput: ((InputAction) -> Void)?
    var onFailure: (() -> Void)?
    private let lock = NSLock()
    private var active = false
    private var swallowed = Set<Int64>()
    private var tap: CFMachPort?
    private(set) var installed = false
    var gestureHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "AltTab2 keyboard"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
    }

    private func run() {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<Keyboard>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        DispatchQueue.main.async { [weak self] in self?.installed = true }
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            cancel()
            send(.cancel)
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        defer { lock.unlock() }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let command = event.flags.contains(.maskCommand)
        if type == .flagsChanged, active, !command {
            active = false
            send(.commit)
        } else if type == .keyUp, swallowed.remove(code) != nil {
            return nil
        } else if type == .keyDown {
            if code == 48, command, !event.flags.contains(.maskAlternate), !event.flags.contains(.maskControl) {
                active = true
                swallowed.insert(code)
                send(.tab(event.flags.contains(.maskShift) ? -1 : 1))
                return nil
            }
            if active {
                if code == 53 {
                    active = false
                    swallowed.insert(code)
                    send(.cancel)
                    return nil
                }
                if (123...126).contains(code) {
                    swallowed.insert(code)
                    send(.arrow(Int(code)))
                    return nil
                }
                if code == 12 || code == 13 {
                    let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 || swallowed.contains(code)
                    swallowed.insert(code)
                    if !repeated { send(.selectedAction(code == 13 ? .close : .quit)) }
                    return nil
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func send(_ action: InputAction) {
        DispatchQueue.main.async { [weak self] in self?.onInput?(action) }
    }
}

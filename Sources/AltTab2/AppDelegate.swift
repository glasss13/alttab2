import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = Controller()
    private let commands = CommandPort()
    private var setup: NSWindow?
    private var message: NSTextField?
    private var retryTimer: Timer?
    private var running = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        commands.handler = { [weak self] command in
            guard let self else { return [:] }
            if command == "quit" {
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return ["quitting": true]
            }
            if command == "setup" { self.showSetup() }
            return self.controller.status()
        }
        commands.start()
        controller.onInputFailure = { [weak self] in
            self?.showSetup()
            self?.message?.stringValue =
                "Keyboard access was refused. Enable AltTab2 in Accessibility and Input Monitoring, then reopen it."
        }
        attemptStart()
        if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() || CommandLine.arguments.contains("--setup") {
            showSetup()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !controller.panel.isVisible { showSetup() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === setup {
            retryTimer?.invalidate()
            retryTimer = nil
            setup = nil
            message = nil
        }
    }

    private func attemptStart() {
        if AXIsProcessTrusted(), !running {
            running = true
            controller.start()
        }
        if running { controller.thumbnails.enabled = CGPreflightScreenCaptureAccess() }
        updateStatus()
    }

    private func showSetup() {
        if setup == nil { makeSetup() }
        NSApp.activate(ignoringOtherApps: true)
        setup?.makeKeyAndOrderFront(nil)
        updateStatus()
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.attemptStart() }
    }

    private func updateStatus() {
        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        message?.stringValue =
            ax && screen
            ? "Ready. Quit the original AltTab before using Cmd+Tab here. Close this window to keep AltTab2 running."
            : "\(ax ? "✓" : "○") Accessibility — switch windows and read the keyboard\n\(screen ? "✓" : "○") Screen Recording — show window thumbnails"
        if ax && screen {
            retryTimer?.invalidate()
            retryTimer = nil
        }
    }

    private func makeSetup() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 530, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AltTab2"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: "Your windows. Instantly.")
        heading.font = .systemFont(ofSize: 25, weight: .semibold)
        let description = NSTextField(
            wrappingLabelWithString:
                "Tap ⌘ Tab to switch back. Hold ⌘ to see your windows. Use Tab or the arrow keys to choose, then release ⌘."
        )
        description.font = .systemFont(ofSize: 13)
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 12)
        message = status
        let accessibility = NSButton(
            title: "Enable Accessibility…", target: self, action: #selector(grantAccessibility))
        let recording = NSButton(title: "Enable Screen Recording…", target: self, action: #selector(grantRecording))
        let permissions = NSStackView(views: [accessibility, recording])
        permissions.spacing = 10
        let login = NSButton(checkboxWithTitle: "Start at login", target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let quit = NSButton(title: "Quit AltTab2", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let license = NSButton(title: "License & attribution…", target: self, action: #selector(showLicense))
        let actions = NSStackView(views: [license, quit])
        actions.spacing = 10
        for view in [heading, description, status, permissions, login, actions] { stack.addArrangedSubview(view) }
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
        ])
        setup = window
    }

    @objc private func showLicense() {
        let notice = NSAlert()
        notice.messageText = "AltTab2 — GNU GPL version 3"
        notice.informativeText =
            "Copyright © 2026 glasss13. Includes code from AltTab, copyright lwouis and contributors.\n\nYou may redistribute and modify this software under GPLv3. It comes WITHOUT ANY WARRANTY.\n\nSource: https://github.com/glasss13/alttab2"
        notice.addButton(withTitle: "Close")
        notice.addButton(withTitle: "View license")
        notice.addButton(withTitle: "View attribution")
        let response = notice.runModal()
        let resource: String
        switch response {
        case .alertSecondButtonReturn: resource = "LICENSE.txt"
        case .alertThirdButtonReturn: resource = "THIRD_PARTY.md"
        default: return
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent(resource) { NSWorkspace.shared.open(url) }
    }

    @objc private func grantAccessibility() {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func grantRecording() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = .off
            message?.stringValue = "Could not change login startup: \(error.localizedDescription)"
        }
    }
}

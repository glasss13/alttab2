import Foundation

final class CommandPort {
    static let name = "local.alttab2.app.commands" as CFString
    private var port: CFMessagePort?
    var handler: ((String) -> [String: Any])?

    func start() {
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        port = CFMessagePortCreateLocal(
            nil, Self.name,
            { _, _, data, info in
                guard let data, let info, let command = String(data: data as Data, encoding: .utf8) else { return nil }
                let server = Unmanaged<CommandPort>.fromOpaque(info).takeUnretainedValue()
                let value = server.handler?(command) ?? [:]
                guard
                    let encoded = try? JSONSerialization.data(
                        withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
                else { return nil }
                return Unmanaged.passRetained(encoded as CFData)
            }, &context, nil)
        if let port, let source = CFMessagePortCreateRunLoopSource(nil, port, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    static func send(_ command: String) -> Bool {
        guard let port = CFMessagePortCreateRemote(nil, name) else {
            fputs("AltTab2 is not running.\n", stderr)
            return false
        }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            port, 0, command.data(using: .utf8)! as CFData, 2, 3, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let reply else {
            fputs("AltTab2 did not answer (\(status)).\n", stderr)
            return false
        }
        print(String(data: reply.takeRetainedValue() as Data, encoding: .utf8) ?? "{}")
        return true
    }
}

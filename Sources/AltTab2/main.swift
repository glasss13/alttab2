import AppKit

let commands: Set<String> = ["status", "quit"]
if let argument = CommandLine.arguments.dropFirst().first, argument.hasPrefix("--"),
    commands.contains(String(argument.dropFirst(2)))
{
    exit(CommandPort.send(String(argument.dropFirst(2))) ? 0 : 1)
}
if NSRunningApplication.runningApplications(withBundleIdentifier: "local.alttab2.app").contains(where: {
    $0.processIdentifier != getpid()
}) {
    _ = CommandPort.send("setup")
    exit(0)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()

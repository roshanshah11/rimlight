import AppKit
import RimlightCore

let args = Array(CommandLine.arguments.dropFirst())
if !args.isEmpty { exit(CLI.run(args)) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

import AppKit

setenv("GHOSTTY_RESOURCES_DIR", Bundle.main.resourceURL!.appendingPathComponent("ghostty").path, 1)
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(background ? .prohibited : .regular)
NSApplication.shared.run()

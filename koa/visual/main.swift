import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let ownPID = ProcessInfo.processInfo.processIdentifier
var tookFocus = false
let activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
    MainActor.assumeIsolated {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier == ownPID { tookFocus = true }
    }
}
let keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { tookFocus = true }
}
let watcher = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
    MainActor.assumeIsolated {
        if application.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID || application.windows.contains(where: { $0.isKeyWindow || $0.isMainWindow }) { tookFocus = true }
    }
}
Task { @MainActor in
    var failure: Error?
    do {
        try require(CommandLine.arguments.count == 2, "usage: KoaVisual <checkout>")
        let environment = ProcessInfo.processInfo.environment
        let checkout = URL(fileURLWithPath: CommandLine.arguments[1])
        let only = environment["ONLY"] ?? ""
        var selected: [KoaFixture: KoaSelection] = [:]
        for item in only.split(whereSeparator: \.isWhitespace) {
            let parts = item.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let fixture = try requireValue(KoaFixture(rawValue: String(parts[0])), "Unknown fixture: \(parts[0])")
            if parts.count == 1 { selected[fixture] = .all }
            else {
                let name = String(parts[1])
                try require(!name.isEmpty, "Capture name is empty")
                switch selected[fixture] {
                case .all?: break
                case .captures(var names)?: names.insert(name); selected[fixture] = .captures(names)
                case nil: selected[fixture] = .captures([name])
                }
            }
        }

        let pixels = try Pixels(references: checkout.appendingPathComponent("koa/visual/__Snapshots__"), output: checkout.appendingPathComponent("build/koa-visual/output"), record: environment["RECORD"] == "1")
        var failures: [String] = []
        for fixture in KoaFixture.allCases {
            if fixture == .scrollbarJumpMountsHistory && selected[fixture] == nil { continue }
            if !selected.isEmpty && selected[fixture] == nil { continue }
            print("FIXTURE \(fixture.rawValue)")
            fflush(stdout)
            let driver = KoaDriver(checkout: checkout, fixture: fixture, selection: selected[fixture] ?? .all, pixels: pixels)
            do {
                try await driver.run()
                if case .captures(let names) = driver.selection {
                    try require(names.isSubset(of: driver.captured), "Unknown capture selection: \(names.subtracting(driver.captured))")
                }
            } catch {
                let message = "\(fixture.rawValue): \(error)"
                failures.append(message)
                print("FAIL \(message)")
            }
            do { try await driver.finish() } catch {
                let message = "\(fixture.rawValue) cleanup: \(error)"
                failures.append(message)
                print("FAIL \(message)")
            }
        }
        let summary = "VISUAL pass=\(pixels.equal) diff=\(pixels.different) missing=\(pixels.missing) errors=\(failures.count)"
        print(summary)
        try require(failures.isEmpty && pixels.different == 0 && pixels.missing == 0, ([summary] + failures).joined(separator: "\n"))
    } catch { failure = error }
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    watcher.invalidate()
    NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    NotificationCenter.default.removeObserver(keyObserver)
    let focusOK = !tookFocus && !application.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier != ownPID
    print("FOCUS untouched=\(focusOK) active=\(application.isActive)")
    if !focusOK {
        let message = "Visual tool took focus during headless snapshots"
        failure = KoaFailure(failure.map { "\($0)\n\(message)" } ?? message)
    }
    if let failure { FileHandle.standardError.write(Data("\(failure)\n".utf8)); exit(1) }
    exit(0)
}
application.run()

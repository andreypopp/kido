import AppKit
import SidebarFeed
import UserNotifications

@MainActor protocol NotificationPoster: AnyObject {
    func post(_ notice: Notice, color: NSColor)
    func withdraw(_ keys: [NoticeKey])
    func withdrawAll()
    func authorize()
    func setBadgeCount(_ count: Int)
}

@MainActor final class SystemNotifications: NSObject, NotificationPoster, UNUserNotificationCenterDelegate {
    private var loggedFailure = false
    private var lastBadgeCount: Int?
    var click: (NoticeTarget) -> Void = { _ in }

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "waiting", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "Waiting for input", options: []),
            UNNotificationCategory(identifier: "failed", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "Failed", options: []),
            UNNotificationCategory(identifier: "done", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "Done", options: []),
        ])
    }

    private func failed(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        note("notifications: \(message)")
    }

    func post(_ notice: Notice, color: NSColor) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.target.host
        content.categoryIdentifier = notice.kind.rawValue
        content.sound = .default
        guard let target = try? JSONEncoder().encode(notice.target) else { return }
        content.userInfo = ["target": target]
        let swatch = FileManager.default.temporaryDirectory.appendingPathComponent("kido-swatch-\(UUID().uuidString).png")
        if (try? Self.swatch(color).write(to: swatch)) != nil,
           let attachment = try? UNNotificationAttachment(identifier: "color", url: swatch) {
            content.attachments = [attachment]
        } else {
            failed("color attachment unavailable")
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(notice.key.owner)|\(notice.key.pane)", content: content, trigger: nil)) { error in
            if let error { Task { @MainActor in self.failed(error.localizedDescription) } }
        }
    }

    static func swatch(_ color: NSColor, side: Int = 128) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.usingColorSpace(.sRGB)!.cgColor)
        let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: CGFloat(side) / 8, dy: CGFloat(side) / 8)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(side) / 4, cornerHeight: CGFloat(side) / 4, transform: nil))
        context.fillPath()
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    func withdraw(_ keys: [NoticeKey]) {
        guard !keys.isEmpty else { return }
        let identifiers = keys.map { "\($0.owner)|\($0.pane)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func withdrawAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func setBadgeCount(_ count: Int) {
        guard lastBadgeCount != count else { return }
        lastBadgeCount = count
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error { Task { @MainActor in self.failed(error.localizedDescription) } }
        }
    }

    func authorize() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .denied {
                Task { @MainActor in self.failed("authorization denied") }
            } else if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if !granted || error != nil {
                        Task { @MainActor in self.failed(error?.localizedDescription ?? "authorization denied") }
                    }
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.categoryIdentifier == Notice.Kind.done.rawValue ? [.banner, .sound] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let data = response.notification.request.content.userInfo["target"] as? Data,
           let target = try? JSONDecoder().decode(NoticeTarget.self, from: data) {
            Task { @MainActor in self.click(target) }
        }
        completionHandler()
    }
}

@MainActor final class RecordedNotifications: NotificationPoster {
    var posts: [Notice] = []
    var colors: [NSColor] = []
    var withdrawals: [NoticeKey] = []
    var withdrawAllCalls = 0
    var authorizeCalls = 0
    var badgeCount = 0
    func post(_ notice: Notice, color: NSColor) { posts.append(notice); colors.append(color) }
    func withdraw(_ keys: [NoticeKey]) { withdrawals += keys }
    func withdrawAll() { withdrawAllCalls += 1 }
    func authorize() { authorizeCalls += 1 }
    func setBadgeCount(_ count: Int) { badgeCount = count }
}

@MainActor final class Notifier {
    #if KIDO_VISUAL || KIDO_STRESS
    static let shared = Notifier(poster: RecordedNotifications())
    #else
    static let shared = Notifier(poster: background ? RecordedNotifications() : SystemNotifications())
    #endif
    let poster: NotificationPoster
    private var state = NotifierState()
    private let owners = NSHashTable<WindowOwner>.weakObjects()
    private var authorized = false

    init(poster: NotificationPoster) { self.poster = poster }

    func connected() {
        guard !authorized else { return }
        authorized = true
        poster.authorize()
    }

    func register(_ owner: WindowOwner) { owners.add(owner) }

    func update(host: Host, snapshotOwner: WindowOwner? = nil) {
        let windows = owners.allObjects.filter { $0.alive && $0.host == host }
        let shown = Set(windows.filter(\.attended).compactMap { $0.snapshot?.client.window })
        for owner in windows {
            guard let snapshot = owner.snapshot, !owner.feedFresh || owner === snapshotOwner else { continue }
            let effects = state.step(owner: owner.notificationID, host: host.clipboardKey,
                snapshot: snapshot, fresh: owner.feedFresh, seen: owner.seen.value, shown: shown, appActive: NSApp.isActive, notifyDone: owner.runtime.settings.notifyDone)
            poster.withdraw(effects.withdraw)
            let color = owner.accents.accent(for: host).color(dark: owner.runtime.background.isDark)
            effects.post.forEach { poster.post($0, color: color) }
            if snapshot.error == nil { owner.feedFresh = false }
        }
        poster.setBadgeCount(state.postedCount)
    }

    func attendanceChanged() {
        for host in Set(owners.allObjects.filter(\.alive).map(\.host)) { update(host: host) }
    }

    func forget(_ owner: WindowOwner) {
        poster.withdraw(state.forget(owner: owner.notificationID).withdraw)
        owners.remove(owner)
        update(host: owner.host)
    }

    func withdrawAll() { poster.withdrawAll(); poster.setBadgeCount(0) }
}

import AppKit
import SidebarFeed
import UserNotifications

@MainActor protocol NotificationPoster: AnyObject {
    func post(_ notice: Notice)
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
        ])
    }

    private func failed(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        note("notifications: \(message)")
    }

    func post(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.target.host
        content.categoryIdentifier = notice.kind.rawValue
        content.sound = .default
        guard let target = try? JSONEncoder().encode(notice.target) else { return }
        content.userInfo = ["target": target]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(notice.key.owner)|\(notice.key.pane)", content: content, trigger: nil)) { error in
            if let error { Task { @MainActor in self.failed(error.localizedDescription) } }
        }
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
        completionHandler([])
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
    var withdrawals: [NoticeKey] = []
    var withdrawAllCalls = 0
    var authorizeCalls = 0
    var badgeCount = 0
    func post(_ notice: Notice) { posts.append(notice) }
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
            let effects = state.step(owner: owner.notificationID, host: host.clipboardKey, identity: owner.identity,
                snapshot: snapshot, fresh: owner.feedFresh, seen: owner.seen.value, shown: shown, appActive: NSApp.isActive)
            poster.withdraw(effects.withdraw)
            effects.post.forEach { poster.post($0) }
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

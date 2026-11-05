import Foundation

struct WindowFrames {
    let preferences: UserDefaults?
    let serverDir: String

    private func key(_ host: Host) -> String {
        switch host {
        case .local: "windowFrame:local:" + serverDir
        case .remote(let alias): "windowFrame:remote:" + alias
        }
    }

    func frame(for host: Host) -> CGRect? {
        guard let data = preferences?.data(forKey: key(host)),
              let frame = try? JSONDecoder().decode(CGRect.self, from: data),
              frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    func save(_ frame: CGRect, for host: Host) {
        preferences?.set(try? JSONEncoder().encode(frame), forKey: key(host))
    }

    static func place(saved: CGRect?, centered: CGRect, screens: [CGRect], main: CGRect, open: [CGRect]) -> CGRect {
        guard var frame = saved else { return centered }
        let screen = screens.filter { $0.intersects(frame) }.max { a, b in
            let first = a.intersection(frame)
            let second = b.intersection(frame)
            return first.width * first.height < second.width * second.height
        } ?? main
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        for _ in 0...open.count {
            guard open.contains(frame) else { break }
            frame.origin.x += 20
            frame.origin.y -= 20
            if frame.maxX > screen.maxX { frame.origin.x = screen.minX }
            if frame.minY < screen.minY { frame.origin.y = screen.maxY - frame.height }
        }
        return frame
    }
}

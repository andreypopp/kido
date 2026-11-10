import AppKit
import GhosttyKit
import ImageIO
import QuickLookUI
import Synchronization
import UniformTypeIdentifiers

private final class PreviewBuffer: @unchecked Sendable {
    private var image: ghostty_image_s
    init(_ image: ghostty_image_s) { self.image = image }
    deinit { ghostty_image_free(&image) }
}

struct PreviewPixels: Sendable {
    let width: Int
    let height: Int
    let format: ghostty_image_format_e
    let data: Data
}

enum PreviewSource: Sendable {
    case pixels(PreviewPixels, id: UInt32)
    case file(Data, name: String)
}

extension PreviewPixels {
    init?(taking image: inout ghostty_image_s) {
        guard let pixels = image.data else { return nil }
        width = Int(image.width)
        height = Int(image.height)
        format = image.format
        let buffer = PreviewBuffer(image)
        data = Data(bytesNoCopy: pixels, count: image.len, deallocator: .custom { _, _ in withExtendedLifetime(buffer) {} })
        image = ghostty_image_s()
    }
}

@MainActor final class ImagePreview: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    static let shared = ImagePreview()
    private override init() { super.init() }
    private enum Preview {
        case writing(UUID)
        case ready(URL, NSRect)
    }
    private var preview: Preview?
    nonisolated private static let files = PrivateTemporaryDirectory("kido-previews")
    nonisolated private static let stopped = Mutex(false)
    nonisolated static var directory: URL { files.directory }

    func show(_ source: PreviewSource, rect: NSRect) {
        Task {
            guard await prepare(source, rect: rect) else { return }
            guard NSApp.isActive else { return close() }
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }
    }

    func prepare(_ source: PreviewSource, rect: NSRect) async -> Bool {
        close()
        let token = UUID()
        preview = .writing(token)
        let result = await Task.detached(priority: .userInitiated) { Result { try Self.write(source) } }.value
        guard case .writing(let current) = preview, current == token else {
            if case .success(let url) = result { Self.remove(url) }
            return false
        }
        switch result {
        case .success(let url):
            preview = .ready(url, rect)
            return true
        case .failure(let error):
            preview = nil
            debug("preview failed: \(error)")
            return false
        }
    }

    var ready: Bool {
        if case .ready = preview { return true }
        return false
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func close() {
        let old = preview
        preview = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.delegate === self {
            panel.orderOut(nil)
            panel.dataSource = nil
            panel.delegate = nil
        }
        if case .ready(let url, _) = old { Self.remove(url) }
    }

    func sweep() { Self.files.sweep() }

    func stop() {
        close()
        Self.stopped.withLock { stopped in
            stopped = true
            Self.files.remove()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        if case .ready = preview { return 1 }
        return 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        if case .ready(let url, _) = preview { return url as NSURL }
        return nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        if case .ready(_, let rect) = preview { return rect }
        return .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 || event.keyCode == 53 {
            close()
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { close() }

    nonisolated private static func write(_ source: PreviewSource) throws -> URL {
        guard !stopped.withLock({ $0 }) else { throw CocoaError(.userCancelled) }
        let data: Data, name: String
        switch source {
        case .file(let bytes, let raw):
            data = bytes
            var safe = raw.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? "preview"
            safe = safe.components(separatedBy: .controlCharacters).joined(separator: "_")
            while safe.utf8.count > 255 { safe.removeLast() }
            name = safe.isEmpty || safe == "." || safe == ".." ? "preview" : safe
        case .pixels(let image, let id):
            let channels: Int
            switch image.format {
            case GHOSTTY_IMAGE_FORMAT_GRAY: channels = 1
            case GHOSTTY_IMAGE_FORMAT_GRAY_ALPHA: channels = 2
            case GHOSTTY_IMAGE_FORMAT_RGB: channels = 3
            case GHOSTTY_IMAGE_FORMAT_RGBA: channels = 4
            default: throw CocoaError(.fileWriteUnknown)
            }
            let alpha = channels == 2 || channels == 4
            guard let space = CGColorSpace(name: channels <= 2 ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: image.data as CFData),
                  let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                                   bitsPerPixel: channels * 8, bytesPerRow: image.width * channels,
                                   space: space, bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : .none).rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw CocoaError(.fileWriteUnknown) }
            let encoded = NSMutableData()
            guard let png = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(png, cg, nil)
            guard CGImageDestinationFinalize(png) else { throw CocoaError(.fileWriteUnknown) }
            data = encoded as Data
            name = "image-\(id).png"
        }
        return try stopped.withLock { stopped in
            guard !stopped else { throw CocoaError(.userCancelled) }
            try files.prepare()
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                try? FileManager.default.removeItem(at: folder)
                throw CocoaError(.fileWriteUnknown)
            }
            return url
        }
    }

    nonisolated private static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

extension PaneView {
    func surfacePoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x, y: bounds.height - point.y - renderInsets.top)
    }

    func screenRect(_ rect: NSRect) -> NSRect {
        let local = NSRect(x: rect.minX, y: bounds.height - renderInsets.top - rect.maxY, width: rect.width, height: rect.height)
        let converted = convert(local, to: nil)
        return window?.convertToScreen(converted) ?? converted
    }

    func contentHit(_ point: NSPoint) -> ghostty_hit_s {
        var hit = ghostty_hit_s()
        let position = surfacePoint(point)
        guard !disposed, bounds.contains(point), !inRenderBand(point) else { return hit }
        _ = ghostty_surface_content_at(surface, position.x, position.y, &hit)
        return hit
    }

    func activateContent(_ hit: ghostty_hit_s, at point: NSPoint) {
        guard !disposed else { return }
        let position = surfacePoint(point)
        if hit.kind == GHOSTTY_HIT_LINK {
            _ = ghostty_surface_open_link_at(surface, position.x, position.y)
        } else {
            var hit = hit
            var image = ghostty_image_s()
            guard ghostty_surface_image_copy(surface, &hit, &image) == GHOSTTY_SUCCESS else { return }
            defer { ghostty_image_free(&image) }
            guard let pixels = PreviewPixels(taking: &image), window != nil else { return }
            let rect = screenRect(NSRect(x: hit.rect.x, y: hit.rect.y, width: hit.rect.width, height: hit.rect.height))
            ImagePreview.shared.show(.pixels(pixels, id: hit.image_id), rect: rect)
        }
    }
}

import AppKit
import KoClientKit

enum PasteboardMIME {
    static let limit = 64 << 20, textLimit = 1 << 20
    private static let types: [(mime: String, type: NSPasteboard.PasteboardType)] = [
        ("text/plain", .string), ("image/png", .png), ("image/tiff", .tiff), ("image/jpeg", .init("public.jpeg")),
        ("text/html", .html), ("text/uri-list", .fileURL),
    ]

    @MainActor static func available(_ board: NSPasteboard) -> [String] {
        let present = Set(board.types ?? [])
        let png = present.contains(.png) || present.contains(.tiff)
        return types.compactMap { entry in
            switch entry.type {
            case .png: png ? entry.mime : nil
            case .tiff: present.contains(.tiff) && !present.contains(.png) ? entry.mime : nil
            default: present.contains(entry.type) ? entry.mime : nil
            }
        }
    }

    @MainActor static func read(_ board: NSPasteboard, _ mimes: [String]) -> [KoClipboardContent] {
        mimes.compactMap { mime -> KoClipboardContent? in
            let data: Data? = switch mime {
            case "text/plain": board.string(forType: .string).map { Data($0.utf8) }
            case "text/uri-list": (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }.joined(separator: "\r\n").data(using: .utf8)
            default: types.first(where: { $0.mime == mime }).flatMap { board.data(forType: $0.type) }
            }
            guard let data, data.count <= (mime.hasPrefix("text/") ? textLimit : limit),
                  !mime.hasPrefix("text/") || !data.contains(0) else { return nil }
            return KoClipboardContent(mime: mime, data: data)
        }
    }

    nonisolated static func written(_ mime: String, _ data: Data) -> (type: NSPasteboard.PasteboardType, data: Data)? {
        let alias = ["text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING"].contains(mime)
        guard let type = alias ? .string : types.first(where: { $0.mime == mime })?.type, data.count <= limit else { return nil }
        guard alias || mime.hasPrefix("text/") else { return (type, data) }
        guard data.count <= textLimit, !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        guard type == .fileURL else { return (type, data) }
        let url = text.trimmingCharacters(in: .newlines)
        return url.contains(where: \.isNewline) ? nil : (type, Data(url.utf8))
    }

    nonisolated static func items(_ contents: [KoClipboardContent]) -> [(type: NSPasteboard.PasteboardType, data: Data)]? {
        var items: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        for content in contents {
            guard let item = written(content.mime, content.data) else { return nil }
            if !items.contains(where: { $0.type == item.type }) { items.append(item) }
        }
        return items
    }
}

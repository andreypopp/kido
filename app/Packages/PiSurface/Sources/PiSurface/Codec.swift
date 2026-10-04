import Foundation

public struct Frame: Sendable {
    public let header: [String]
    public let bytes: Data
}

public struct Codec {
    private var buffer = Data()
    public init() {}
    public mutating func receive(_ bytes: Data) -> [Frame] {
        buffer.append(bytes)
        var frames: [Frame] = []
        let prefix = Data("\u{1b}]6767;".utf8)
        while let start = buffer.range(of: prefix) {
            if start.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start.lowerBound) }
            guard let end = buffer.firstIndex(of: 7) else { break }
            let body = buffer.subdata(in: (buffer.startIndex + prefix.count)..<end)
            buffer.removeSubrange(buffer.startIndex...end)
            guard let text = String(data: body, encoding: .utf8), let separator = text.firstIndex(of: ";"),
                  let decoded = Data(base64Encoded: String(text[text.index(after: separator)...])) else { continue }
            let header = text[..<separator].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard [2, 4].contains(header.count), ["0", "1"].contains(header.last!),
                  header.dropFirst(header.count == 4 ? 1 : 0).allSatisfy({ UInt64($0) != nil }) else { continue }
            frames.append(Frame(header: header, bytes: decoded))
        }
        if buffer.count > 4096 { buffer.removeAll() }
        return frames
    }
    public static func encode(_ json: String, client: String? = nil, number: Int = 1) -> [Data] {
        let data = Data(json.utf8), size = client == nil ? 3000 : 300
        return stride(from: 0, to: data.count, by: size).enumerated().map { index, offset in
            let end = min(offset + size, data.count), last = end == data.count ? 1 : 0
            let header = client.map { "\($0),\(number),\(index),\(last)" } ?? "\(number + index),\(last)"
            return Data("\u{1b}]6767;\(header);\(data.subdata(in: offset..<end).base64EncodedString())\u{7}".utf8)
        }
    }
}

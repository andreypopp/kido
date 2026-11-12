import Foundation

public struct KoClipboardContent: Equatable {
    public let mime: String
    public let data: Data

    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }
}

// The C view of clipboard contents and of the type names that go with them, for the call's duration.
public func withClipboard<Item, Result>(
    _ contents: [KoClipboardContent], available: [String] = [],
    item: (UnsafePointer<CChar>, UnsafeRawPointer, Int) -> Item,
    _ body: (UnsafeBufferPointer<Item>, UnsafeBufferPointer<UnsafePointer<CChar>?>) -> Result
) -> Result {
    let names = contents.map { strdup($0.mime)! }
    let types = available.map { UnsafePointer(strdup($0)!) as UnsafePointer<CChar>? }
    defer {
        names.forEach { free($0) }
        types.forEach { free(UnsafeMutablePointer(mutating: $0)) }
    }
    let datas = contents.map { $0.data as NSData }
    let items = contents.indices.map { item(names[$0], datas[$0].bytes, datas[$0].length) }
    return withExtendedLifetime(datas) {
        items.withUnsafeBufferPointer { items in types.withUnsafeBufferPointer { body(items, $0) } }
    }
}

import AppKit

private func imagePixels(_ image: CGImage) -> (width: Int, height: Int, channels: [UInt8])? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4)))
}


@MainActor final class Pixels {
    let references: URL
    let output: URL
    let record: Bool
    var equal = 0
    var different = 0
    var missing = 0
    init(references: URL, output: URL, record: Bool) throws {
        self.references = references
        self.output = output
        self.record = record
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }
    func verify(_ image: NSImage, capture: String, owner: String, fixture: KoaFixture) throws {
        let name = String(owner.prefix { $0 != "(" }) + "." + capture + ".png"
        let reference = references.appendingPathComponent(name)
        let bitmap = try requireValue(NSBitmapImageRep(data: try requireValue(image.tiffRepresentation)))
        if record {
            try requireValue(bitmap.representation(using: .png, properties: [:])).write(to: reference)
            print("RECORD \(fixture.rawValue)/\(capture)")
            return
        }
        let actual = try requireValue(bitmap.cgImage.flatMap(imagePixels))
        guard let old = NSImage(contentsOf: reference)?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(imagePixels) else {
            missing += 1
            try requireValue(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
            print("MISSING \(fixture.rawValue)/\(capture)")
            return
        }
        let sameSize = old.width == actual.width && old.height == actual.height
        let delta = sameSize ? zip(old.channels, actual.channels).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) } : nil
        if let delta, delta <= 1 { equal += 1; return }
        different += 1
        try requireValue(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
        let width = max(old.width, actual.width), height = max(old.height, actual.height)
        let diff = try requireValue(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let bytes = try requireValue(diff.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<4 {
                    let before = x < old.width && y < old.height ? old.channels[(y * old.width + x) * 4 + channel] : 0
                    let after = x < actual.width && y < actual.height ? actual.channels[(y * actual.width + x) * 4 + channel] : 0
                    bytes[(y * width + x) * 4 + channel] = channel == 3 ? 255 : UInt8(abs(Int(before) - Int(after)))
                }
            }
        }
        try requireValue(diff.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name.replacingOccurrences(of: ".png", with: ".diff.png")))
        print("DIFF \(fixture.rawValue)/\(capture) max_delta=\(delta.map(String.init) ?? "dimension-change") actual=\(actual.width)x\(actual.height) reference=\(old.width)x\(old.height)")
    }
}

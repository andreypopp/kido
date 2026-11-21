import AppKit
import SnapshotTesting

func imagePixels(_ image: CGImage) -> (width: Int, height: Int, channels: [UInt8])? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4)))
}

func pixelsDiffing() -> Diffing<NSImage> {
    let reference = Diffing<NSImage>.image
    return .init(toData: reference.toData, fromData: reference.fromData) { old, new in
        if let old = old.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(imagePixels),
           let new = new.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(imagePixels),
           old.width == new.width, old.height == new.height {
            if old.channels == new.channels { return nil }
            if zip(old.channels, new.channels).allSatisfy({ abs(Int($0) - Int($1)) <= 1 }) { return nil }
        }
        return reference.diff(old, new)
    }
}

extension Snapshotting where Value == NSImage, Format == NSImage {
    static var pixels: Snapshotting { .init(pathExtension: "png", diffing: pixelsDiffing()) }
}


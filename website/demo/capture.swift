import Foundation
import CoreGraphics
import ScreenCaptureKit
import AVFoundation
import AppKit

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let queue = DispatchQueue(label: "kido-demo-capture")
    var started = false

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000,
                                              AVVideoMaxKeyFrameIntervalKey: 60]
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, CMSampleBufferGetImageBuffer(sample) != nil else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sample.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sample) }
    }

    func finish() async throws {
        guard started else { throw NSError(domain: "No window frames captured; check that the Mac remains unlocked", code: 1) }
        queue.sync { input.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Capture encoding failed", code: 2) }
    }
}

@main
struct Capture {
    static func main() async {
        do {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            guard session?["CGSSessionScreenIsLocked"] as? Bool != true else {
                throw NSError(domain: "Mac session is locked: unlock the Mac before recording", code: 5)
            }
            guard CGPreflightScreenCaptureAccess() else {
                throw NSError(domain: "Screen Recording permission required for the app launching this command (System Settings > Privacy & Security > Screen Recording)", code: 3)
            }
            let id = UInt32(CommandLine.arguments[1])!
            let seconds = Double(CommandLine.arguments[2])!
            let url = URL(fileURLWithPath: CommandLine.arguments[3])
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw NSError(domain: "Private kitty window not found", code: 4)
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width) * 2
            configuration.height = Int(window.frame.height) * 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 5
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            let recorder = try Recorder(url: url, width: configuration.width, height: configuration.height)
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            try await stream.startCapture()
            print("Capturing isolated kitty window \(id): \(configuration.width)×\(configuration.height)")
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            try await stream.stopCapture()
            try await recorder.finish()
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }
}

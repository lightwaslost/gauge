// Records only one app's windows (including sheets) to ProRes 4444 with alpha.
// Usage: record-window <AppName> <output.mov> [maxSeconds]
// Stops on SIGINT/SIGTERM or after maxSeconds. Build: swiftc -O record-window.swift -o record-window
import AppKit
import AVFoundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private var started = false
    private let lock = NSLock()

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        lock.lock(); defer { lock.unlock() }
        if !started {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }

    func finish() async {
        lock.lock(); input.markAsFinished(); lock.unlock()
        await writer.finishWriting()
    }
}

_ = NSApplication.shared  // initializes CoreGraphics before NSScreen is touched
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: record-window <AppName> <output.mov> [maxSeconds]\n".data(using: .utf8)!)
    exit(2)
}
let appName = args[1]
let output = URL(fileURLWithPath: args[2])
let maxSeconds = args.count > 3 ? Double(args[3]) ?? 600 : 600

let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
let windows = content.windows.filter { $0.owningApplication?.applicationName == appName && $0.frame.width > 400 && $0.windowLayer == 0 }
guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
      let app = window.owningApplication,
      let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) ?? content.displays.first else {
    FileHandle.standardError.write("No visible window for \(appName)\n".data(using: .utf8)!)
    exit(1)
}

// Normally capture every window of the app (so sheets are included), cropped to the main window.
// If the window isn't on the current Space, fall back to capturing that one window directly.
let onScreen = window.isOnScreen
let filter = onScreen
    ? SCContentFilter(display: display, including: [app], exceptingWindows: [])
    : SCContentFilter(desktopIndependentWindow: window)
if !onScreen { print("note: window is off screen; recording it alone (sheets won't appear)") }
let scale = NSScreen.screens.first { $0.frame.width == display.frame.width }?.backingScaleFactor ?? 2
let config = SCStreamConfiguration()
let local = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
if onScreen { config.sourceRect = local }
config.width = Int(local.width * scale)
config.height = Int(local.height * scale)
config.pixelFormat = kCVPixelFormatType_32BGRA
config.backgroundColor = .clear
config.showsCursor = false
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
config.queueDepth = 8

let recorder = try Recorder(url: output, width: config.width, height: config.height)
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "record"))
try await stream.startCapture()
print("recording \(appName) \(config.width)x\(config.height) -> \(output.path)")

let done = DispatchSemaphore(value: 0)
func stop() {
    Task {
        try? await stream.stopCapture()
        await recorder.finish()
        print("saved \(output.path)")
        done.signal()
    }
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { stop() }
    source.resume()
    return source
}
DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds) { stop() }
_ = sources
await withCheckedContinuation { continuation in
    DispatchQueue.global().async { done.wait(); continuation.resume() }
}

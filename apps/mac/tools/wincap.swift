import ScreenCaptureKit
import AVFoundation
import CoreGraphics

// wincap <CGWindowID> <out.mov> [scale] — record ONE window (never a screen
// region) via ScreenCaptureKit + AVAssetWriter until SIGINT/SIGTERM.
// Build: swiftc -O -parse-as-library -o wincap wincap.swift
// Used for docs/playground-demo.mp4 with tools/playctl driving the
// buttons; `playctl front` first — SCK suspends capture of windows on
// an inactive Space (screencapture -v cannot record a single window).

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var seen = 0
    var kept = 0

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        seen += 1
        let img = CMSampleBufferGetImageBuffer(sb) != nil
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let rawStatus = atts?.first?[.status] as? Int
        if seen <= 3 {
            log("buf \(seen) valid=\(sb.isValid) img=\(img) status=\(String(describing: rawStatus))")
        }
        guard type == .screen, sb.isValid, img else { return }
        guard let raw = rawStatus, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            started = true
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
        }
        if input.isReadyForMoreMediaData {
            input.append(sb)
            kept += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error)")
        exit(2)
    }

    func finish() {
        log("frames seen=\(seen) kept=\(kept)")
        guard started else { log("no frames captured"); exit(3) }
        input.markAsFinished()
        writer.finishWriting { exit(0) }
    }
}

@main
struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let widNum = UInt32(args[1]) else {
            log("usage: wincap <windowID> <out.mov> [scale]")
            exit(64)
        }
        _ = CGMainDisplayID()   // force the WindowServer connection (CGS init)
        let out = URL(fileURLWithPath: args[2])
        try? FileManager.default.removeItem(at: out)

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == CGWindowID(widNum) }) else {
            log("window \(widNum) not found")
            exit(1)
        }
        log("window: \(win.title ?? "?") app=\(win.owningApplication?.applicationName ?? "?") onScreen=\(win.isOnScreen) frame=\(win.frame)")

        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        // H.264 tops out at 4096 px — point size by default; an optional
        // third arg scales (2 = Retina-native, "video quality looks low",
        // user 2026-09-01). Even dims either way.
        let scale = CommandLine.arguments.count > 3
            ? (Int(CommandLine.arguments[3]) ?? 1) : 1
        let w = (Int(win.frame.width) * scale / 2) * 2
        let h = (Int(win.frame.height) * scale / 2) * 2
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let recorder = try Recorder(url: out, width: w, height: h)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "wincap"))
        try await stream.startCapture()
        log("recording \(widNum) \(w)x\(h) -> \(out.path)")

        let stop: @Sendable () -> Void = {
            Task {
                try? await stream.stopCapture()
                recorder.finish()
            }
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let s1 = DispatchSource.makeSignalSource(signal: SIGINT)
        s1.setEventHandler { stop() }
        s1.resume()
        let s2 = DispatchSource.makeSignalSource(signal: SIGTERM)
        s2.setEventHandler { stop() }
        s2.resume()
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

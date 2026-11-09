@preconcurrency import AVFoundation
import AppKit
import Testing
@testable import PasteMan

private actor LiveRecordingExporter: ScreenRecordingExporting {
    func export(segments: [URL], directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        for (index, url) in segments.enumerated() {
            let copy = directory.deletingLastPathComponent().appendingPathComponent("raw-" + UUID().uuidString + ".mp4")
            try FileManager.default.copyItem(at: url, to: copy)
            let asset = AVURLAsset(url: url)
            for track in try await asset.load(.tracks) {
                let range = try await track.load(.timeRange)
                print("原始片段 \(index)：\(track.mediaType.rawValue)，起点 \(range.start.seconds)，时长 \(range.duration.seconds)")
            }
        }
        return try await ScreenRecordingExporter().export(segments: segments, directory: directory, progress: progress)
    }
}

@Suite("录屏实机采集", .serialized, .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_LIVE_RECORDING"] == "1"))
@MainActor struct ScreenRecordingLiveTests {
    @Test func fullScreenAndRegionCaptureCanPauseResumeAndPlay() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "调用进程必须已获屏幕录制权限；本测试不请求授权")
        let screen = try #require(NSScreen.screens.first)
        let id = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_RECORDING_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("EasyMacOS-Live-" + UUID().uuidString).path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "RecordingLive." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let variants: [(Bool, Bool, Bool, ScreenRecordingQuality)] = [
            (true, false, false, .standard), (false, false, false, .standard),
            (true, true, false, .standard), (false, true, false, .standard), (false, false, true, .standard),
            (true, false, false, .lightweight), (false, false, false, .lightweight), (false, false, true, .lightweight),
        ]
        for (full, audio, still, quality) in variants {
            let region = still ? CGRect(x: screen.frame.maxX - 100, y: screen.frame.minY, width: 100, height: 100)
                : CGRect(x: 100, y: 100, width: 640, height: 400)
            let target = try #require(ScreenRecordingTarget.region(displayID: id, frame: screen.frame,
                scale: screen.backingScaleFactor, globalRect: full ? screen.frame : region))
            let recording = ScreenRecordingCoordinator(exporter: LiveRecordingExporter(), defaults: defaults, countdownInterval: .milliseconds(10))
            recording.select(mode: full ? .fullScreen : .region,
                             options: ScreenRecordingOptions(systemAudio: audio, microphone: false, directory: root, quality: quality))
            recording.confirm(target)
            for _ in 0..<600 where recording.phase != .recording && recording.phase != .failed { try await Task.sleep(for: .milliseconds(20)) }
            #expect(recording.phase == .recording, "启动失败：\(recording.errorMessage ?? "")")
            guard recording.phase == .recording else { continue }
            try await Task.sleep(for: .milliseconds(2000))
            recording.togglePause()
            for _ in 0..<300 where recording.phase == .pausing { try await Task.sleep(for: .milliseconds(20)) }
            #expect(recording.phase == .paused, "暂停失败：\(recording.errorMessage ?? "")")
            let elapsed = recording.elapsed
            try await Task.sleep(for: .milliseconds(500))
            #expect(recording.elapsed == elapsed)
            recording.togglePause()
            for _ in 0..<300 where recording.phase == .starting { try await Task.sleep(for: .milliseconds(20)) }
            #expect(recording.phase == .recording)
            try await Task.sleep(for: .milliseconds(2000))
            recording.stop()
            for _ in 0..<1500 where recording.phase != .idle && recording.phase != .failed { try await Task.sleep(for: .milliseconds(20)) }
            #expect(recording.phase == .idle, "保存失败：\(recording.errorMessage ?? "")")
            let url = try #require(recording.savedURL)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            #expect(duration > 3 && duration < 5)
            let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await video.load(.naturalSize) == target.pixelSize(for: quality))
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            #expect(reader.startReading())
            var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            #expect(reader.status == .completed && count > (still ? 0 : 5))
            print("实机录屏检查：\(full ? "全屏" : "区域")，\(quality.rawValue)，\(duration) 秒，\(count) 帧，\(url.path)")
        }
    }
}

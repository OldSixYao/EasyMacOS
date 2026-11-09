import AppKit
@preconcurrency import AVFoundation
import Darwin
import Synchronization
import Testing

@testable import PasteMan

/// 显式启用并已有授权时才运行；应先用独立进程的合成画面覆盖显示器。
@Suite("录屏缓冲测量", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_RECORDING_BUFFER_OUTPUT"] != nil))
@MainActor struct RecordingBufferBenchmarks {
    @Test func compareFormatsAndQueueDepths() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "本测量不请求屏幕录制授权")
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["EASYMACOS_RECORDING_BUFFER_OUTPUT"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seconds = min(60, max(2, Double(environment["EASYMACOS_RECORDING_BENCHMARK_SECONDS"] ?? "3") ?? 3))
        let screen = try #require(NSScreen.screens.first)
        let id = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let target = try #require(ScreenRecordingTarget.region(displayID: id, frame: screen.frame,
            scale: screen.backingScaleFactor, globalRect: screen.frame))
        let variants: [(String, Int, OSType, ScreenRecordingQuality)] = [
            ("bgra-8-standard", 8, kCVPixelFormatType_32BGRA, .standard),
            ("nv12-8-standard", 8, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .standard),
            ("nv12-6-standard", 6, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .standard),
            ("nv12-4-standard", 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .standard),
            ("nv12-8-lightweight", 8, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .lightweight),
        ]
        let ordered = environment["EASYMACOS_RECORDING_BENCHMARK_REVERSE"] == "1" ? Array(variants.reversed()) : variants
        var results: [String: [String: Double]] = [:]
        for (name, depth, format, quality) in ordered {
            if let selected = environment["EASYMACOS_RECORDING_BENCHMARK_VARIANT"], name != selected { continue }
            let sampleLayout = Mutex((format: OSType(0), bytes: 0))
            let engine = SystemScreenRecordingEngine(queueDepth: depth, pixelFormat: format, observeFrame: { type, bytes in
                sampleLayout.withLock { $0.format = type; $0.bytes = max($0.bytes, bytes) }
            })
            let url = directory.appendingPathComponent(name + "-" + UUID().uuidString + ".mp4")
            let baseline = try footprint()
            let peak = Mutex(baseline)
            let sampler = Task.detached {
                while !Task.isCancelled {
                    if let sample = try? recordingFootprint() { peak.withLock { $0 = max($0, sample) } }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
            let cpuBefore = cpuSeconds()
            let began = ContinuousClock.now
            do {
                try await engine.start(target: target, options: ScreenRecordingOptions(quality: quality), url: url)
                print("开始录屏缓冲测量：\(name)，\(seconds) 秒")
                try await Task.sleep(for: .seconds(seconds))
                let active = try footprint()
                try await engine.stop()
                let cpu = cpuSeconds() - cpuBefore
                let elapsed = began.duration(to: .now)
                sampler.cancel()
                await sampler.value
                try await Task.sleep(for: .milliseconds(150))
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
                #expect(try await video.load(.naturalSize) == target.pixelSize(for: quality))
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
                reader.add(output)
                try #require(reader.startReading())
                var frames = 0
                while autoreleasepool(invoking: { output.copyNextSampleBuffer() != nil }) { frames += 1 }
                let sustained = reader.status == .completed && duration > seconds * 0.6 && frames > Int(seconds * 5)
                if depth >= 6 { #expect(sustained, "默认及原始队列必须持续输出可播放的画面") }
                let layout = sampleLayout.withLock { $0 }
                #expect(layout.format == format && layout.bytes > 0, "系统应交付所请求的像素格式")
                let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                results[name] = [
                    "baseline_bytes": Double(baseline), "active_bytes": Double(active),
                    "peak_bytes": Double(peak.withLock { $0 }), "settled_bytes": Double(try footprint()),
                    "cpu_seconds": cpu, "wall_seconds": wall, "video_seconds": duration,
                    "frames": Double(frames), "sustained": sustained ? 1 : 0,
                    "pixel_format": Double(layout.format), "frame_bytes": Double(layout.bytes),
                ]
                print("完成录屏缓冲测量：\(name)，\(frames) 帧，\(duration) 秒")
            } catch {
                sampler.cancel()
                await sampler.value
                try? await engine.stop()
                throw error
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }

    private func footprint() throws -> UInt64 { try recordingFootprint() }
    private func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

private func recordingFootprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw CocoaError(.fileReadUnknown) }
    return info.phys_footprint
}

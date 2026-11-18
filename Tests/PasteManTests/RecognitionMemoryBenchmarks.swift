import AppKit
import Darwin
import Synchronization
import Testing

@testable import PasteMan

/// 独立进程中的合成识别负载；日常测试不执行，不读取桌面或剪贴板。
@Suite("识别内存测量", .serialized) struct RecognitionMemoryBenchmarks {
    @Test func largeImageRecognition() async throws {
        guard let path = ProcessInfo.processInfo.environment["EASYMACOS_RECOGNITION_BENCHMARK_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try autoreleasepool {
            let context = try #require(CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8,
                bytesPerRow: 3840 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
            return try ScreenshotRenderer.render(base: #require(context.makeImage()),
                pointSize: CGSize(width: 3840, height: 2160), annotations: [80, 1000, 2000].map { y in
                    ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 80, y: y)],
                        color: AnnotationColor.palette[5], width: 8,
                        text: "中文文字识别 Memory check 12345",
                        textStyle: AnnotationTextStyle(fontFamily: "PingFang SC", fontSize: 64))
                })
        }
        var samples: [RecognitionMemorySample] = []
        for index in 0..<3 {
            let before = try recognitionFootprint()
            let peak = Mutex((parent: before, combined: before, worker: UInt64(0)))
            let queue = DispatchQueue(label: "EasyMacOS.RecognitionMemorySampler")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1))
            timer.setEventHandler {
                if let bytes = try? recognitionFootprint() {
                    let worker = ScreenshotRecognitionProcess.shared.processIdentifier.flatMap(recognitionWorkerFootprint) ?? 0
                    peak.withLock {
                        $0.parent = max($0.parent, bytes)
                        $0.combined = max($0.combined, bytes + worker)
                        $0.worker = max($0.worker, worker)
                    }
                }
            }
            timer.resume()
            let start = ContinuousClock.now
            let text: String
            do {
                text = try await SystemScreenshotTextRecognizer.shared.recognize(
                    .image(image, pointSize: CGSize(width: 3840, height: 2160), annotations: []), progress: { _ in })
            } catch {
                timer.cancel()
                throw error
            }
            let duration = start.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            let completed = try recognitionFootprint()
            timer.cancel()
            queue.sync {}
            #expect(text.components(separatedBy: "Memory check 12345").count == 4)
            #expect(text.contains("中文文字识别"), "\(text)")
            try await Task.sleep(for: .milliseconds(300))
            let measured = peak.withLock { $0 }
            samples.append(RecognitionMemorySample(iteration: index, milliseconds: milliseconds, before: before,
                peak: max(completed, measured.parent), combinedPeak: measured.combined, workerPeak: measured.worker,
                completed: completed, settled: try recognitionFootprint(), text: text))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: directory.appendingPathComponent("recognition-memory.json"))
    }
}

private struct RecognitionMemorySample: Codable {
    let iteration: Int
    let milliseconds: Double
    let before: UInt64
    let peak: UInt64
    let combinedPeak: UInt64
    let workerPeak: UInt64
    let completed: UInt64
    let settled: UInt64
    let text: String
}

private func recognitionWorkerFootprint(_ pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
    }
    return result == 0 ? info.ri_phys_footprint : nil
}

private func recognitionFootprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    try #require(result == KERN_SUCCESS)
    return info.phys_footprint
}

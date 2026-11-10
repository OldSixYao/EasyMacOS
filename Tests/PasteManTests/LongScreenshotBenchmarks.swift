import AppKit
import Darwin
import ImageIO
import Synchronization
import Testing
@testable import PasteMan

/// 合成数据、独立进程及原始像素检查；报告只写入显式指定的本机目录。
@Suite("长截屏性能测量", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_LONG_BENCHMARK_OUTPUT"] != nil))
struct LongScreenshotBenchmarks {
    @Test func measurePipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = environment["EASYMACOS_LONG_BENCHMARK_CASE"] ?? "stitch"
        let root = URL(fileURLWithPath: try #require(environment["EASYMACOS_LONG_BENCHMARK_OUTPUT"]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let iterations = Int(environment["EASYMACOS_LONG_BENCHMARK_ITERATIONS"] ?? "7") ?? 7
        let width = 2560, frameHeight = 1440, step = 120, count = 13
        let height = frameHeight + (count - 1) * step
        let page = try longBenchmarkPage(width: width, height: height)
        let frames = try (0..<count).map {
            try #require(page.cropping(to: CGRect(x: 0, y: $0 * step, width: width, height: frameHeight)))
        }
        var pixels: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, width, frameHeight, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess)
        let buffer = try #require(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 160, CVPixelBufferGetBytesPerRow(buffer) * frameHeight)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var durations: [Double] = [], peaks: [Double] = [], baselines: [Double] = [], copies: [Int] = [], sampleCounts: [Int] = []
        for iteration in 0...max(1, iterations) {
            let baseline = try longBenchmarkFootprint()
            let peak = Mutex((bytes: baseline, count: 0))
            let sampleQueue = DispatchQueue(label: "app.easymacos.long-benchmark.memory")
            let sampler = DispatchSource.makeTimerSource(queue: sampleQueue)
            sampler.schedule(deadline: .now(), repeating: .milliseconds(1))
            sampler.setEventHandler {
                if let value = try? longBenchmarkFootprint() {
                    peak.withLock { $0.bytes = max($0.bytes, value); $0.count += 1 }
                }
            }
            sampler.resume()
            let start = ContinuousClock.now
            var copied = 0
            switch scenario {
            case "frames":
                let mailbox = LongScreenshotFrameMailbox()
                for index in 0..<120 {
                    if mailbox.publish(buffer, at: Double(index) / 30) { copied += 1 }
                    if index.isMultiple(of: 4) { _ = try #require(try mailbox.read()) }
                }
                let latest = try #require(try mailbox.read())
                #expect(latest.image.width == width && latest.image.height == frameHeight)
                mailbox.close()
            case "match":
                var previous = try LongScreenshotFeatures(frames[0])
                for frame in frames.dropFirst() {
                    let features = try LongScreenshotFeatures(frame)
                    #expect(try previous.match(features).displacement == step)
                    previous = features
                }
            case "stitch", "stitchFresh":
                let stitcher = LongScreenshotStitcher(scale: 2)
                for (index, stored) in frames.enumerated() {
                    // 流式场景不让已经消费的原图一直留在测试输入数组中。
                    let frame = scenario == "stitchFresh"
                        ? try #require(page.cropping(to: CGRect(x: 0, y: index * step, width: width, height: frameHeight))) : stored
                    _ = try await stitcher.append(frame)
                }
                for _ in 0..<4 {
                    let last = scenario == "stitchFresh"
                        ? try #require(page.cropping(to: CGRect(x: 0, y: (count - 1) * step, width: width, height: frameHeight))) : frames.last!
                    #expect(try await stitcher.append(last).added == 0)
                }
                let document = try #require(try await stitcher.finish())
                #expect(document.image.width == width && document.image.height == height)
                let actual = try #require(document.image.dataProvider?.data as Data?)
                let expected = try #require(page.dataProvider?.data as Data?)
                for y in stride(from: 0, to: height, by: 19) {
                    #expect(actual[(y * width * 4)..<((y + 1) * width * 4)]
                        == expected[(y * width * 4)..<((y + 1) * width * 4)])
                }
            case "preview", "export":
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LongBenchmark-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("pixels.rgba")
                try #require(FileManager.default.createFile(atPath: url.path, contents: nil))
                let file = try FileHandle(forWritingTo: url)
                let data = try #require(page.dataProvider?.data as Data?)
                for _ in 0..<8 { try file.write(contentsOf: data) }
                try file.close()
                let document = try LongScreenshotDocument(directory: directory, width: width, height: height * 8, scale: 2)
                if scenario == "preview" {
                    for y in stride(from: 0, to: document.image.height, by: 3072) {
                        let tile = try await LongScreenshotTileWorker.shared.render(document: document,
                            rect: CGRect(x: 0, y: y, width: width, height: min(1024, document.image.height - y)),
                            annotations: [], maximumWidth: 1280)
                        #expect(tile.width == 1280)
                    }
                } else {
                    let result = try await ScreenshotRenderWorker.shared.export(base: document.image,
                        pointSize: document.pointSize, annotations: [])
                    let source = try #require(CGImageSourceCreateWithData(result.png as CFData, nil))
                    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                    #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
                    #expect(properties[kCGImagePropertyPixelHeight] as? Int == height * 8)
                }
            default: Issue.record("未知测量场景：\(scenario)")
            }
            let elapsed = start.duration(to: .now)
            sampler.cancel()
            sampleQueue.sync {}
            if iteration > 0 {
                durations.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                peaks.append(Double(peak.withLock { $0.bytes }))
                baselines.append(Double(baseline))
                copies.append(copied)
                sampleCounts.append(peak.withLock { $0.count })
            }
        }
        let report: [String: Any] = ["scenario": scenario, "milliseconds": durations, "peakBytes": peaks,
            "baselineBytes": baselines, "copiedFrames": copies, "width": width, "frameHeight": frameHeight,
            "stitchedHeight": height, "iterations": durations.count, "memorySampleCounts": sampleCounts]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("\(scenario).json"), options: .atomic)
        print("长截屏测量完成：\(scenario)，\(durations.count) 次，报告 \(root.path)")
    }
}

private func longBenchmarkPage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.12, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // 非周期纹理与大面积空白并存，避免只测容易匹配的均匀噪点。
    for y in stride(from: 8, to: height - 24, by: 37) {
        let hash = UInt32(y + 1) &* 2_654_435_761
        context.setFillColor(CGColor(red: CGFloat(80 + (hash & 127)) / 255,
            green: CGFloat(80 + ((hash >> 8) & 127)) / 255,
            blue: CGFloat(80 + ((hash >> 16) & 127)) / 255, alpha: 1))
        for x in stride(from: 30, to: width - 400, by: 83) {
            context.fill(CGRect(x: x, y: y, width: 20 + Int((hash >> (x % 16)) & 31), height: 14 + y % 11))
        }
    }
    return try #require(context.makeImage())
}

private func longBenchmarkFootprint() throws -> UInt64 {
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

import Foundation
@preconcurrency import AVFoundation
import Testing

@testable import PasteMan

/// 相同的合成源文件及测试代码可分别放到旧源码和新源码中，比较实际导出器。
@Suite("录屏交付对比", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_RECORDING_EXPORT_REPLAY_OUTPUT"] != nil))
struct RecordingExportReplayBenchmarks {
    @Test func measureCurrentExporter() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["EASYMACOS_RECORDING_EXPORT_REPLAY_SOURCE"]))
        let root = URL(fileURLWithPath: try #require(environment["EASYMACOS_RECORDING_EXPORT_REPLAY_OUTPUT"]))
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        var results: [String: [Double]] = [:]
        for count in [1, 2] {
            var samples: [Double] = []
            for iteration in 0..<8 {
                let began = ContinuousClock.now
                let url = try await ScreenRecordingExporter().export(segments: Array(repeating: source, count: count), directory: session)
                let elapsed = began.duration(to: .now)
                #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - duration * Double(count)) < 0.1)
                if iteration > 0 {
                    samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                }
                try FileManager.default.removeItem(at: url)
            }
            results["\(count)片段交付_毫秒"] = samples
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json"), options: .atomic)
    }
}

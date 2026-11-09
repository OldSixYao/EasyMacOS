@preconcurrency import AVFoundation
import AppKit
import Testing
@testable import PasteMan

@Suite("录屏媒体导出", .serialized) @MainActor struct ScreenRecordingExportTests {
    private func video(_ url: URL, red: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixel: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<180 {
                for x in 0..<320 {
                    let offset = y * stride + x * 4
                    base[offset] = red ? 20 : 220
                    base[offset + 1] = 30
                    base[offset + 2] = red ? 220 : 20
                    base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        #expect(writer.status == .completed)
    }

    private func segment(root: URL, name: String, red: Bool, frequencies: [Double]) async throws -> URL {
        let sourceURL = root.appendingPathComponent(name + "-video.mov")
        try await video(sourceURL, red: red)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: sourceURL)
        let source = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let range = try await source.load(.timeRange)
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(range, of: source, at: .zero)
        for (index, frequency) in frequencies.enumerated() {
            let url = root.appendingPathComponent(name + "-audio-\(index).caf")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            let samples = try #require(buffer.floatChannelData)[0]
            for frame in 0..<48_000 { samples[frame] = Float(sin(2 * .pi * frequency * Double(frame) / 48_000) * 0.2) }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let asset = AVURLAsset(url: url)
            let source = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let audio = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try audio.insertTimeRange(range, of: source, at: .zero)
        }
        let url = root.appendingPathComponent(name + ".mov")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: .mov)
        return url
    }

    private func tonePower(_ values: [Float], frequency: Double, sampleRate: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (index, value) in values.enumerated() {
            let angle = 2 * Double.pi * frequency * Double(index) / sampleRate
            real += Double(value) * cos(angle)
            imaginary += Double(value) * sin(angle)
        }
        return hypot(real, imaginary) / Double(max(1, values.count))
    }

    @Test func unwritableDestinationPreservesOriginalAndAllowsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingWriteFailure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await video(source, red: true)
        let original = try Data(contentsOf: source)
        let destination = root.appendingPathComponent("missing")
        do {
            _ = try await ScreenRecordingExporter().export(segments: [source], directory: destination)
            Issue.record("不可写的目标目录不应导出成功")
        } catch { }
        #expect(try Data(contentsOf: source) == original)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let saved = try await ScreenRecordingExporter().export(segments: [source], directory: destination)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func sequentialSegmentsPreserveFramesDurationCodecAndBothAudioSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingMedia-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 四种组合：无声音、系统声音、麦克风、两种声音。
        for (index, frequencies) in [[], [440.0], [880.0], [440.0, 880.0]].enumerated() {
            let first = try await segment(root: root, name: "\(index)-first", red: true, frequencies: frequencies)
            let second = try await segment(root: root, name: "\(index)-second", red: false, frequencies: frequencies)
            let session = root.appendingPathComponent("session-\(index)")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
            let exporter = ScreenRecordingExporter()
            let url = try await exporter.export(segments: [first, second], directory: session)
            #expect(await exporter.lastMethod == (frequencies.count > 1 ? .reencode : .passthrough))
            #expect(url.pathExtension == "mp4" && FileManager.default.fileExists(atPath: first.path))
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 2) < 0.1)
            let videos = try await asset.loadTracks(withMediaType: .video)
            #expect(videos.count == 1)
            let format = try #require(try await videos[0].load(.formatDescriptions).first)
            #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            #expect(reader.startReading())
            var redFrames = 0, blueFrames = 0
            while let sample = output.copyNextSampleBuffer() {
                let image = try #require(CMSampleBufferGetImageBuffer(sample))
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let bytes = try #require(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
                if bytes[2] > bytes[0] { redFrames += 1 } else { blueFrames += 1 }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
            #expect(reader.status == .completed && redFrames >= 28 && blueFrames >= 28)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            #expect(audios.count == (frequencies.isEmpty ? 0 : 1))
            if let audio = audios.first {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                ])
                reader.add(output)
                #expect(reader.startReading())
                var values: [Float] = []
                while let sample = output.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    var bytes = [UInt8](repeating: 0, count: length)
                    #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr)
                    values += bytes.withUnsafeBytes { raw in
                        stride(from: 0, to: length - 3, by: 4).map { raw.loadUnaligned(fromByteOffset: $0, as: Float.self) }
                    }
                }
                #expect(values.count > 90_000)
                for frequency in frequencies { #expect(tonePower(values, frequency: frequency, sampleRate: 48_000) > 0.015) }
            }
        }
        // 同一秒生成的文件不会覆盖。
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        #expect(files.count == 4)
    }

    @Test func singleMP4WithoutMixingPreservesCompressedBytesAndDoesNotOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingCopy-" + UUID().uuidString)
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await segment(root: root, name: "single", red: true, frequencies: [])
        let remuxed = try await ScreenRecordingExporter().export(segments: [source], directory: session)
        let original = try Data(contentsOf: remuxed)
        let exporter = ScreenRecordingExporter()
        let first = try await exporter.export(segments: [remuxed], directory: session)
        #expect(await exporter.lastMethod == .copy)
        let second = try await exporter.export(segments: [remuxed], directory: session)
        #expect(first != second && first != remuxed && second != remuxed)
        #expect(try Data(contentsOf: first) == original)
        #expect(try Data(contentsOf: second) == original)
        #expect(try Data(contentsOf: remuxed) == original)
        let tracks = try await AVURLAsset(url: second).loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test func invalidSegmentFailsWithoutDiscardingOtherSegmentsOrLeavingPartialOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingInvalid-" + UUID().uuidString)
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid.mov")
        try await video(valid, red: true)
        let invalid = root.appendingPathComponent("invalid.mp4")
        try Data([0, 1, 2]).write(to: invalid)
        await #expect(throws: (any Error).self) {
            _ = try await ScreenRecordingExporter().export(segments: [valid, invalid], directory: session)
        }
        #expect(FileManager.default.fileExists(atPath: valid.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path).isEmpty)
    }

    @Test func measureExportFastPaths() async throws {
        guard let path = ProcessInfo.processInfo.environment["EASYMACOS_RECORDING_EXPORT_OUTPUT"] else { return }
        let root = URL(fileURLWithPath: path)
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("synthetic-1080p.mp4")
        try await benchmarkVideo(source)
        var values: [String: [Double]] = [:]
        for count in [1, 2] {
            let segments = Array(repeating: source, count: count)
            var before: [Double] = [], after: [Double] = []
            for iteration in 0..<8 {
                let oldURL = session.appendingPathComponent(UUID().uuidString + ".mp4")
                var began = ContinuousClock.now
                try await reencodedReference(segments, to: oldURL)
                let oldTime = began.duration(to: .now)
                began = .now
                let exporter = ScreenRecordingExporter()
                let final = try await exporter.export(segments: segments, directory: session)
                let newTime = began.duration(to: .now)
                #expect(await exporter.lastMethod == (count == 1 ? .copy : .passthrough))
                #expect(abs(try await AVURLAsset(url: final).load(.duration).seconds - Double(count * 10)) < 0.1)
                if iteration > 0 {
                    before.append(milliseconds(oldTime))
                    after.append(milliseconds(newTime))
                }
                try FileManager.default.removeItem(at: oldURL)
                try FileManager.default.removeItem(at: final)
            }
            values["\(count)片段_原最高质量导出_毫秒"] = before
            values["\(count)片段_免重编码交付_毫秒"] = after
        }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json"), options: .atomic)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func reencodedReference(_ urls: [URL], to url: URL) async throws {
        let composition = AVMutableComposition()
        let video = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let source = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let range = try await source.load(.timeRange)
            try video.insertTimeRange(range, of: source, at: cursor)
            if cursor == .zero { video.preferredTransform = try await source.load(.preferredTransform) }
            cursor = cursor + range.duration
        }
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await export.export(to: url, as: .mp4)
    }

    private func benchmarkVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        for index in 0..<300 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            try autoreleasepool {
                var pixel: CVPixelBuffer?
                try #require(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess)
                let buffer = try #require(pixel)
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
                context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.7, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
                context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1))
                context.fill(CGRect(x: index * 5, y: 150, width: 200, height: 200))
                try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 10, preferredTimescale: 600))
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        try #require(writer.status == .completed)
    }
}

@preconcurrency import AVFoundation
import Foundation

protocol ScreenRecordingExporting: Sendable {
    func export(segments: [URL], directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}
extension ScreenRecordingExporting {
    func export(segments: [URL], directory: URL) async throws -> URL {
        try await export(segments: segments, directory: directory, progress: { _ in })
    }
}

actor ScreenRecordingExporter: ScreenRecordingExporting {
    enum Method { case copy, passthrough, reencode }
    private(set) var lastMethod: Method?
    private struct Segment {
        let url: URL
        let asset: AVURLAsset
        let video: AVAssetTrack
        let range: CMTimeRange
        let transform: CGAffineTransform
        let videoFormat: CMFormatDescription
        let audio: [AVAssetTrack]
        let audioFormats: [CMFormatDescription]
    }

    /// 所有源片段在成功交付前保持原样，重命名失败或取消后仍可重试。
    func export(segments urls: [URL], directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lastMethod = nil
        var method: Method?
        let segments = try await inspect(urls)
        guard let first = segments.first else { throw ScreenRecordingError.empty }
        let temp = directory.appendingPathComponent("merged-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        try Task.checkCancellation()

        if segments.count == 1, first.url.pathExtension.lowercased() == "mp4", first.audio.count <= 1,
            CMFormatDescriptionGetMediaSubType(first.videoFormat) == kCMVideoCodecType_H264 {
            // 同卷文件复制可由文件系统克隆数据；不重新读取像素或改变压缩后的音视频。
            try FileManager.default.copyItem(at: first.url, to: temp)
            method = .copy
        } else {
            let (composition, audio) = try await compose(segments)
            var compatible = false
            if canPassThrough(segments) {
                compatible = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                    with: composition, outputFileType: .mp4)
            }
            if compatible {
                do {
                    try await encode(composition, audio: [], preset: AVAssetExportPresetPassthrough,
                        to: temp, progress: progress)
                    method = .passthrough
                } catch {
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: temp)
                }
            }
            if method == nil {
                try await encode(composition, audio: audio, preset: AVAssetExportPresetHighestQuality,
                    to: temp, progress: progress)
                method = .reencode
            }
        }
        try Task.checkCancellation()
        let final = try deliver(temp, in: directory.deletingLastPathComponent())
        lastMethod = method
        progress(1)
        return final
    }

    private func inspect(_ urls: [URL]) async throws -> [Segment] {
        var segments: [Segment] = []
        for url in urls {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable),
                let video = try await asset.loadTracks(withMediaType: .video).first,
                let videoFormat = try await video.load(.formatDescriptions).first else {
                throw ScreenRecordingError.empty
            }
            let range = try await video.load(.timeRange)
            guard range.duration.isNumeric, range.duration > .zero else { throw ScreenRecordingError.empty }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            var audioFormats: [CMFormatDescription] = []
            for track in audio {
                guard let format = try await track.load(.formatDescriptions).first else { throw ScreenRecordingError.empty }
                audioFormats.append(format)
            }
            segments.append(Segment(url: url, asset: asset, video: video, range: range,
                transform: try await video.load(.preferredTransform), videoFormat: videoFormat,
                audio: audio, audioFormats: audioFormats))
        }
        return segments
    }

    private func canPassThrough(_ segments: [Segment]) -> Bool {
        guard let first = segments.first, first.audio.count <= 1,
            CMFormatDescriptionGetMediaSubType(first.videoFormat) == kCMVideoCodecType_H264 else { return false }
        return segments.allSatisfy { segment in
            segment.transform == first.transform && segment.audio.count == first.audio.count
                && CMFormatDescriptionEqual(segment.videoFormat, otherFormatDescription: first.videoFormat)
                && zip(segment.audioFormats, first.audioFormats).allSatisfy {
                    CMFormatDescriptionEqual($0, otherFormatDescription: $1)
                }
        }
    }

    private func compose(_ segments: [Segment]) async throws -> (AVMutableComposition, [AVMutableCompositionTrack]) {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ScreenRecordingError.empty
        }
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        for segment in segments {
            try Task.checkCancellation()
            try video.insertTimeRange(segment.range, of: segment.video, at: cursor)
            if cursor == .zero { video.preferredTransform = segment.transform }
            for (index, source) in segment.audio.enumerated() {
                while audioTracks.count <= index {
                    guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw ScreenRecordingError.empty
                    }
                    audioTracks.append(track)
                }
                let overlap = CMTimeRangeGetIntersection(segment.range, otherRange: try await source.load(.timeRange))
                if overlap.duration > .zero {
                    try audioTracks[index].insertTimeRange(overlap, of: source,
                        at: cursor + overlap.start - segment.range.start)
                }
            }
            cursor = cursor + segment.range.duration
        }
        return (composition, audioTracks)
    }

    private func encode(_ composition: AVMutableComposition, audio: [AVMutableCompositionTrack], preset: String,
                        to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ScreenRecordingError.empty
        }
        if audio.count > 1 {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audio.map { track in
                let input = AVMutableAudioMixInputParameters(track: track)
                input.setVolume(0.5, at: .zero)
                return input
            }
            exporter.audioMix = mix
        }
        let states = exporter.states(updateInterval: 0.5)
        let progressTask = Task {
            for await state in states {
                if Task.isCancelled { break }
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { progressTask.cancel() }
        try await exporter.export(to: url, as: .mp4)
    }

    private func deliver(_ temp: URL, in directory: URL) throws -> URL {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "EasyMacOS " + date.string(from: Date())
        for index in 0..<10_000 {
            let suffix = index == 0 ? "" : " (\(index))"
            let final = directory.appendingPathComponent(name + suffix + ".mp4")
            do { try FileManager.default.moveItem(at: temp, to: final); return final }
            catch {
                if FileManager.default.fileExists(atPath: final.path) { continue }
                throw error
            }
        }
        throw ScreenRecordingError.outputDirectory
    }
}

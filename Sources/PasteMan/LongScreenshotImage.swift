import AppKit
import Darwin
import PasteManCore
import Vision

struct LongScreenshotLimits: Sendable {
    var maximumHeight = 50_000
    var maximumPixels = 100_000_000
    var maximumDuration: Duration = .seconds(180)
}

enum LongScreenshotError: Error, LocalizedError {
    case selection, permission, targetChanged, unstable, overlap, capacity, timeout, captureTimedOut, scrollUnavailable
    var errorDescription: String? {
        switch self {
        case .selection: L.t("Select a scrolling area inside one window (at least 80 × 80 points).", "请在单个窗口内框选至少 80 × 80 点的纵向滚动区域。")
        case .permission: L.t("Allow Screen Recording and Accessibility in System Settings, then start again.", "请在系统设置中允许屏幕录制与辅助功能，然后重新开始长截屏。")
        case .targetChanged: L.t("The target window or display changed. Select the scrolling area again.", "目标窗口或显示配置已变化，请重新框选滚动区域。")
        case .unstable: L.t("The page kept changing, so capture was stopped.", "页面持续变化，已停止采集。")
        case .overlap: L.t("The overlap could not be matched reliably, so capture was stopped.", "无法可靠匹配画面重叠区域，已停止采集。")
        case .capacity: L.t("The image reached the height or pixel limit.", "已达到五万像素高度或一亿总像素上限。")
        case .timeout: L.t("The three-minute capture limit was reached.", "已达到三分钟采集时限。")
        case .captureTimedOut: L.t("Timed out waiting for the next screen image. Capture was stopped.", "等待屏幕画面超时，已停止采集。")
        case .scrollUnavailable: L.t("This system could not deliver scrolling to the selected window without moving the pointer.",
            "当前系统无法在保持鼠标自由移动的情况下向所选窗口投递滚动，已停止采集。")
        }
    }
}

/// 文件只由本次流程持有；映射像素不要求把整张长图复制进堆内存。
final class LongScreenshotDocument: Sendable {
    let directory: URL
    let image: CGImage
    let pointSize: CGSize
    init(directory: URL, width: Int, height: Int, scale: CGFloat) throws {
        self.directory = directory
        let data = try Data(contentsOf: directory.appendingPathComponent("pixels.rgba"), options: .alwaysMapped)
        guard data.count == width * height * 4, let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ScreenshotImageError.allocationFailed }
        self.image = image
        pointSize = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// 两档灰度特征都保留逐像素纵向位置；粗匹配不足时用文字细节交叉确认。
struct LongScreenshotFeatures: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    private let signals: [Bool]
    private let detailWidth: Int
    private let detail: [UInt8]
    private let gradients: [UInt8]
    private let registrationImage: CGImage
    init(_ image: CGImage) throws {
        width = min(96, image.width)
        height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
            let data = context.data else { throw ScreenshotImageError.allocationFailed }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let values = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
        bytes = values
        var signals = [Bool](repeating: false, count: height * 3)
        for y in 0..<height {
            for band in 0..<3 {
                let start = width / 12 + band * (width / 4)
                let end = min(width * 11 / 12, start + width / 4)
                var low = 255, high = 0, vertical = 0
                for x in stride(from: start, to: end, by: 2) {
                    let value = Int(values[y * width + x])
                    low = min(low, value); high = max(high, value)
                    if y + 1 < height { vertical = max(vertical, abs(value - Int(values[(y + 1) * width + x]))) }
                }
                signals[y * 3 + band] = high - low >= 10 || vertical >= 10
            }
        }
        detailWidth = min(384, image.width)
        guard let fine = CGContext(data: nil, width: detailWidth, height: height, bitsPerComponent: 8,
            bytesPerRow: detailWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
            let buffer = fine.data else { throw ScreenshotImageError.allocationFailed }
        fine.interpolationQuality = .low
        fine.draw(image, in: CGRect(x: 0, y: 0, width: detailWidth, height: height))
        let detail = Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: detailWidth * height))
        self.detail = detail
        var gradients = [UInt8](repeating: 0, count: detail.count)
        // 每张画面的边缘强度只计算一次；所有位移候选复用同一份精确整数结果。
        for y in 0..<max(0, height - 1) {
            if y.isMultiple(of: 64) { try Task.checkCancellation() }
            for x in 0..<max(0, detailWidth - 1) {
                let index = y * detailWidth + x, value = Int(detail[index])
                gradients[index] = UInt8(max(abs(value - Int(detail[index + 1])), abs(value - Int(detail[index + detailWidth]))))
            }
        }
        self.gradients = gradients
        guard let registrationImage = fine.makeImage() else { throw ScreenshotImageError.allocationFailed }
        self.registrationImage = registrationImage
        self.signals = signals
    }

    private func rowError(_ y: Int, _ other: Self, _ otherY: Int, band: Int? = nil) -> Double {
        let start: Int
        let end: Int
        if let band {
            start = width / 12 + band * (width / 4)
            end = min(width * 11 / 12, start + width / 4)
        } else {
            start = width / 12
            end = width * 11 / 12
        }
        var error = 0, count = 0
        for x in stride(from: start, to: end, by: 2) {
            error += min(64, abs(Int(bytes[y * width + x]) - Int(other.bytes[otherY * width + x])))
            count += 1
        }
        return Double(error) / Double(max(1, count))
    }

    func isStable(comparedTo other: Self) -> Bool {
        guard width == other.width, height == other.height else { return false }
        let errors = stride(from: 0, to: height, by: max(1, height / 128)).map { rowError($0, other, $0) }.sorted()
        // 少量动画、光标闪烁与滚动条不影响稳定判定。
        return errors.prefix(max(1, errors.count * 9 / 10)).reduce(0, +) / Double(max(1, errors.count * 9 / 10)) < 0.8
    }

    struct Match: Sendable, Equatable {
        var displacement: Int
        var fixedTop = 0
        var fixedBottom = 0
    }

    private func hasChangedDetail(_ next: Self) -> Bool {
        var changed = 0, rows = 0
        let w = detailWidth
        for y in stride(from: 0, to: height - 1, by: 2) {
            var rowChanged = 0
            for x in stride(from: max(1, w / 24), to: w * 23 / 24 - 1, by: 2) {
                let i = y * w + x, value = Int(next.detail[i])
                guard abs(value - Int(detail[i])) >= 8,
                    next.gradients[i] >= 6 else { continue }
                rowChanged += 1
            }
            changed += rowChanged
            if rowChanged >= 3 { rows += 1 }
            if changed >= 64 && rows >= 6 { return true }
        }
        return false
    }

    func match(_ next: Self) throws -> Match {
        try autoreleasepool { try matchScoped(next) }
    }

    private func matchScoped(_ next: Self) throws -> Match {
        guard width == next.width, detailWidth == next.detailWidth, height == next.height else { throw LongScreenshotError.overlap }
        // 稳定等待可忽略小动画；零位移判定还须检查细节，避免稀疏文字被空白吞没。
        if isStable(comparedTo: next), !hasChangedDetail(next) { return Match(displacement: 0) }
        let maximum = height / 2
        guard maximum > 0 else { throw LongScreenshotError.overlap }
        do {
            let displacement = try detailMatch(next, candidates: registrationCandidates(next))
            return edgeMatch(next, displacement: displacement)
        } catch LongScreenshotError.overlap {}
        // 三个横向区域分别投票；忽略边缘滚动条与最差的少量动态行。
        func score(_ displacement: Int, band: Int, vertical: Int? = nil, fullOverlap: Bool = false) -> Double? {
            let start = fullOverlap ? 0 : height / 5
            let end = fullOverlap ? height - displacement : min(height * 4 / 5, height - displacement)
            guard end - start > height / 6 else { return nil }
            let first = vertical.map { start + (end - start) * $0 / 3 } ?? start
            let last = vertical.map { start + (end - start) * ($0 + 1) / 3 } ?? end
            var errors: [Double] = []
            for y in stride(from: first, to: last, by: max(1, height / 100)) {
                if signals[(y + displacement) * 3 + band] || next.signals[y * 3 + band] {
                    errors.append(rowError(y + displacement, next, y, band: band))
                }
            }
            guard errors.count >= 3 else { return nil }
            errors.sort()
            let count = max(1, errors.count * 3 / 4)
            return errors.prefix(count).reduce(0, +) / Double(count)
        }
        var scores: [(Int, Double)] = []
        for d in 1...maximum {
            if d.isMultiple(of: 64) { try Task.checkCancellation() }
            let bands = (0..<3).compactMap { score(d, band: $0) }
            if !bands.isEmpty { scores.append((d, bands.reduce(0, +) / Double(bands.count))) }
        }
        scores.sort { $0.1 < $1.1 }
        var best = scores.first ?? (0, Double.infinity)
        let unique = !scores.contains { abs($0.0 - best.0) > 2 && $0.1 < max(best.1 + 0.4, best.1 * 1.5) }
        let regionVotes = (0..<3).filter { vertical in
            let regions = (0..<3).compactMap { score(best.0, band: $0, vertical: vertical) }
            return !regions.isEmpty && regions.reduce(0, +) / Double(regions.count) < 5
        }.count
        if best.1 >= 4.5 || !unique || regionVotes < 2 {
            var fullScores: [(Int, Double)] = []
            for displacement in 1...maximum {
                if displacement.isMultiple(of: 64) { try Task.checkCancellation() }
                let bands = (0..<3).compactMap { score(displacement, band: $0, fullOverlap: true) }
                if !bands.isEmpty { fullScores.append((displacement, bands.reduce(0, +) / Double(bands.count))) }
            }
            fullScores.sort { $0.1 < $1.1 }
            let candidates = Set(scores.prefix(32).map { $0.0 } + fullScores.prefix(32).map { $0.0 }).sorted()
            best.0 = try detailMatch(next, candidates: candidates)
        }

        return edgeMatch(next, displacement: best.0)
    }

    private func edgeMatch(_ next: Self, displacement: Int) -> Match {
        func fixedEdge(fromTop: Bool) -> Int {
            var count = 0
            for i in 0..<(height / 4) {
                let y = fromTop ? i : height - 1 - i
                if rowError(y, next, y) > 2 { break }
                count += 1
            }
            guard count >= 6, count < height / 4 else { return 0 }
            // 白色边距不能仅凭相等就被当作固定栏。
            let samples = stride(from: 0, to: count, by: max(1, count / 12))
            let shifted = samples.map { i -> Double in
                let y = fromTop ? i : height - 1 - i
                let shiftedY = fromTop ? min(height - 1, y + displacement) : max(0, y - displacement)
                return rowError(shiftedY, next, y)
            }
            return shifted.reduce(0, +) / Double(max(1, shifted.count)) > 5 ? count : 0
        }
        return Match(displacement: displacement, fixedTop: fixedEdge(fromTop: true), fixedBottom: fixedEdge(fromTop: false))
    }

    private func registrationCandidates(_ next: Self) throws -> [Int] {
        var candidates = Set<Int>()
        let maximum = height / 2
        // 系统配准只生成候选；即使置信度为一，也必须通过细节重叠与竞争位移核验。
        for band in 0..<4 {
            try Task.checkCancellation()
            let rect = band == 0 ? CGRect(x: 0, y: 0, width: detailWidth, height: height)
                : CGRect(x: (band - 1) * detailWidth / 3, y: 0, width: detailWidth / 3, height: height)
            guard let current = next.registrationImage.cropping(to: rect), let previous = registrationImage.cropping(to: rect) else { continue }
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
            do { try VNImageRequestHandler(cgImage: current, options: [:]).perform([request]) } catch { continue }
            guard let result = request.results?.first as? VNImageTranslationAlignmentObservation else { continue }
            let transform = result.alignmentTransform
            guard transform.tx.isFinite, transform.ty.isFinite, abs(transform.tx) <= 2,
                transform.ty > 0, transform.ty <= CGFloat(maximum) else { continue }
            let value = Int(transform.ty.rounded())
            for d in (value - 1)...(value + 1) where d > 0 && d <= maximum { candidates.insert(d) }
        }

        // 局部纹理签名搜索同时补充配准漏掉的位移和周期重复的竞争峰。
        // 每个签名只读少量真实边缘点，不再为全部位移反复扫描整个重叠范围。
        struct Anchor {
            let samples: [(Int, Int)]
            let change: Int
        }
        var anchors: [Anchor] = []
        let w = detailWidth
        let patchHeight = max(12, min(64, height / 16))
        let patchWidth = max(8, (w - w / 12) / 6)
        for y0 in stride(from: 0, to: height - patchHeight, by: patchHeight) {
            for column in 0..<6 {
                let x0 = w / 24 + column * patchWidth
                var samples: [(Int, Int)] = []
                var change = 0
                for y in stride(from: y0, to: y0 + patchHeight - 1, by: max(1, patchHeight / 6)) {
                    for x in stride(from: x0, to: min(w - 1, x0 + patchWidth), by: max(1, patchWidth / 8)) {
                        let index = y * w + x, value = Int(next.detail[index])
                        if next.gradients[index] >= 6 {
                            samples.append((index, value)); change += min(64, abs(Int(detail[index]) - value))
                        }
                    }
                }
                if samples.count >= 6, change > samples.count * 2 {
                    anchors.append(Anchor(samples: samples, change: change))
                }
            }
        }
        anchors.sort { $0.change > $1.change }
        for anchor in anchors.prefix(8) {
            try Task.checkCancellation()
            var scores: [(Int, Int)] = []
            let maximumForAnchor = min(maximum, height - 1 - (anchor.samples.last!.0 / w))
            guard maximumForAnchor > 0 else { continue }
            for d in 1...maximumForAnchor {
                var error = 0
                for (index, value) in anchor.samples { error += min(64, abs(Int(detail[index + d * w]) - value)) }
                scores.append((d, error))
            }
            scores.sort { $0.1 < $1.1 }
            var selected: [Int] = []
            for (d, _) in scores where !selected.contains(where: { abs($0 - d) <= 2 }) {
                candidates.insert(d); selected.append(d)
                if selected.count == 4 { break }
            }
        }
        return candidates.sorted()
    }
    private struct DetailMatch {
        let displacement: Int
        let support: Int
        let error: Double
    }
    private func detailMatch(_ next: Self, candidates: [Int]) throws -> Int {
        let w = detailWidth
        let left = max(1, w / 40), right = w - left
        let columns = 8
        let patchWidth = max(4, (right - left) / columns)
        let patchHeight = max(24, min(80, height / 14))
        var matches: [DetailMatch] = []
        for displacement in candidates {
            try Task.checkCancellation()
            var support = 0, valid = 0, totalError = 0
            var xs = Set<Int>(), ys = Set<Int>()
            var firstY = height, lastY = 0
            for y0 in stride(from: 0, to: height - displacement - patchHeight / 2, by: patchHeight) {
                let y1 = min(height - displacement, y0 + patchHeight)
                for column in 0..<columns {
                    let x0 = left + column * patchWidth
                    let x1 = min(right, x0 + patchWidth)
                    var count = 0, error = 0, unchanged = 0
                    var activeRows = 0
                    for y in stride(from: y0, to: y1 - 1, by: 3) {
                        var rowCount = 0
                        for x in stride(from: x0, to: x1 - 1, by: 2) {
                            let a = (y + displacement) * w + x, b = y * w + x
                            let av = Int(detail[a]), bv = Int(next.detail[b])
                            let gradient = max(gradients[a], next.gradients[b])
                            guard gradient >= 6 else { continue }
                            count += 1; rowCount += 1
                            error += min(64, abs(av - bv))
                            unchanged += min(64, abs(Int(detail[b]) - bv))
                        }
                        if rowCount >= 2 { activeRows += 1 }
                    }
                    guard count >= 10, activeRows >= 2 else { continue }
                    let score = Double(error) / Double(count)
                    let zero = Double(unchanged) / Double(count)
                    // 只让真正随页面移动的细节投票；固定侧栏与空白均不构成位移证据。
                    if score <= 2.8 && zero > max(2, score + 1) {
                        support += count; valid += 1
                        totalError += error
                        xs.insert(column); ys.insert(y0 / patchHeight)
                        firstY = min(firstY, y0); lastY = max(lastY, y1)
                    }
                }
            }
            if valid >= 3, support >= 80, (xs.count >= 2 || ys.count >= 3),
                lastY - firstY >= max(30, height / 30) {
                matches.append(DetailMatch(displacement: displacement, support: support, error: Double(totalError) / Double(support)))
            }
        }
        matches.sort { $0.support > $1.support }
        guard let strongest = matches.first else { throw LongScreenshotError.overlap }
        // 相邻候选的边缘采样数可能不同；在同一支持峰内选像素误差最小的位移，防止累积单像素漂移。
        let best = matches.filter { abs($0.displacement - strongest.displacement) <= 2
            && Double($0.support) >= Double(strongest.support) * 0.6 }.min { $0.error < $1.error } ?? strongest
        if let other = matches.first(where: { abs($0.displacement - best.displacement) > 2 }),
           Double(other.support) >= Double(best.support) * 0.75 { throw LongScreenshotError.overlap }
        return best.displacement
    }

}

protocol LongScreenshotStitching: Sendable {
    func append(_ image: CGImage) async throws -> LongScreenshotStitcher.Progress
    func finish() async throws -> LongScreenshotDocument?
}

actor LongScreenshotStitcher: LongScreenshotStitching {
    struct Progress: Sendable { let width: Int; let height: Int; let added: Int; let reachedLimit: Bool }
    private let limits: LongScreenshotLimits
    private let scale: CGFloat
    private let writeChunk: @Sendable (FileHandle, Data) throws -> Void
    private var directory: URL?
    private var file: FileHandle?
    private var previous: LongScreenshotFeatures?
    private var width = 0
    private var height = 0
    private var frameHeight = 0
    private var fixedTop: Int?
    private var fixedBottom: Int?
    private var rollbackPixels = Data()

    init(scale: CGFloat, limits: LongScreenshotLimits = .init(),
         writeChunk: @escaping @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) {
        self.scale = scale; self.limits = limits; self.writeChunk = writeChunk
    }
    deinit {
        try? file?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func append(_ image: CGImage) async throws -> Progress {
        try await ImageWorkBudget.shared.withPermit(estimatedBytes: image.width * image.height * 9, priority: .userInitiated) {
            try await self.appendAdmitted(image)
        }
    }

    private func appendAdmitted(_ image: CGImage) throws -> Progress {
        // 跨进程图像处理不依赖主线程自动释放池；每帧及时释放系统配准与转换临时对象。
        try autoreleasepool { try appendFrame(image) }
    }

    private func appendFrame(_ image: CGImage) throws -> Progress {
        try Task.checkCancellation()
        let features = try LongScreenshotFeatures(image)
        let match = try previous.map { try $0.match(features) }
        if previous == nil {
            guard image.width > 0, image.height > 0, scale.isFinite, scale > 0,
                image.height <= limits.maximumHeight, image.width <= limits.maximumPixels / image.height
            else { throw LongScreenshotError.capacity }
        }
        guard previous == nil || (image.width == width && image.height == frameHeight)
        else { throw ScreenshotImageError.allocationFailed }
        if let match, match.displacement == 0 {
            // 停稳后用当前视口刷新已有内容，清除已退场的悬浮控件与滚动边缘效果。
            // 顶栏只保留在整图开头，不能在最后一屏重新写入。
            if let file {
                // 已滚动时保留前一帧确认的顶部正文，不把滚动容器的半透明亮边写回长图。
                let top = min(frameHeight - 1, (fixedTop ?? 0) + (height > frameHeight ? 2 : 0))
                let rows = frameHeight - top
                let offset = UInt64((height - rows) * width * 4)
                try withPixelBackup(file: file, offset: offset, count: rows * width * 4) {
                    try file.seek(toOffset: offset)
                    try writePixels(image, rows: (frameHeight - rows)..<frameHeight, to: file)
                }
            }
            return Progress(width: width, height: height, added: 0, reachedLimit: false)
        }
        if previous == nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasyMacOS-Long-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = root
            let url = root.appendingPathComponent("pixels.rgba")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forUpdating: url)
            file = handle
            try writePixels(image, rows: 0..<image.height, to: handle)
            width = image.width; height = image.height; frameHeight = image.height
            previous = features
            return Progress(width: width, height: height, added: height,
                reachedLimit: height >= min(limits.maximumHeight, limits.maximumPixels / width))
        }
        guard let match, let file else { throw ScreenshotImageError.captureUnavailable }
        let top = fixedTop ?? match.fixedTop
        let bottom = fixedBottom ?? match.fixedBottom
        let added = min(match.displacement, max(0, min(limits.maximumHeight, limits.maximumPixels / width) - height))
        guard added > 0 else { return Progress(width: width, height: height, added: 0, reachedLimit: true) }
        guard match.displacement < frameHeight - top - bottom else { throw LongScreenshotError.overlap }
        let stride = width * 4
        // 局部悬浮按钮不会随正文滚动。完整刷新已确认位移的重叠区，
        // 让上一帧的控件由当前帧真实露出的正文覆盖，不能只修复末尾六十四行。
        // 视口顶部两行可能含原生容器的半透明边缘，沿用此前可靠像素；其余重叠区继续刷新。
        let repair = max(1, frameHeight - bottom - match.displacement - top - 2)
        let start = frameHeight - bottom - match.displacement - repair
        let offset = UInt64((height - bottom - repair) * stride)
        // 先备份会被覆盖的重叠区和尾栏；失败时恢复像素及此前可靠的文件长度。
        try withPixelBackup(file: file, offset: offset, count: (bottom + repair) * stride) {
            try file.seek(toOffset: offset)
            try writePixels(image, rows: start..<(start + added + repair), to: file)
            if bottom > 0 { try writePixels(image, rows: (frameHeight - bottom)..<frameHeight, to: file) }
            try file.truncate(atOffset: UInt64((height + added) * stride))
        }
        fixedTop = top; fixedBottom = bottom
        height += added; previous = features
        return Progress(width: width, height: height, added: added, reachedLimit: added < match.displacement
            || height >= min(limits.maximumHeight, limits.maximumPixels / width))
    }

    private func writePixels(_ image: CGImage, rows: Range<Int>, to file: FileHandle) throws {
        try Task.checkCancellation()
        guard !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= image.height
        else { throw ScreenshotImageError.allocationFailed }
        // 刷新范围最多一个视口，按小条带转换并立即释放，避免恢复整帧位图分配。
        for start in stride(from: rows.lowerBound, to: rows.upperBound, by: 256) {
            try autoreleasepool {
                try Task.checkCancellation()
                let height = min(256, rows.upperBound - start)
                guard let strip = image.cropping(to: CGRect(x: 0, y: start, width: image.width, height: height)),
                    let context = CGContext(data: nil, width: image.width, height: height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let pixels = context.data
                else { throw ScreenshotImageError.allocationFailed }
                context.draw(strip, in: CGRect(x: 0, y: 0, width: image.width, height: height))
                let data = Data(bytesNoCopy: pixels, count: image.width * height * 4, deallocator: .none)
                try withExtendedLifetime(context) { try writeChunk(file, data) }
            }
        }
    }

    private func withPixelBackup(file: FileHandle, offset: UInt64, count: Int, operation: () throws -> Void) throws {
        if rollbackPixels.count < count { rollbackPixels = Data(count: max(count, frameHeight * width * 4)) }
        // 复用同一个视口大小的备份，避免每次重叠刷新创建新的大块文件读取对象。
        try rollbackPixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let address = buffer.baseAddress else { throw ScreenshotImageError.allocationFailed }
            var read = 0
            while read < count {
                try Task.checkCancellation()
                let result = pread(file.fileDescriptor, address.advanced(by: read), count - read, off_t(offset) + off_t(read))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw CocoaError(.fileReadUnknown) }
                read += result
            }
            do { try operation() }
            catch {
                try? file.seek(toOffset: offset)
                let backup = Data(bytesNoCopy: address, count: count, deallocator: .none)
                try? file.write(contentsOf: backup)
                try? file.truncate(atOffset: UInt64(height * width * 4))
                throw error
            }
        }
    }

    func finish() throws -> LongScreenshotDocument? {
        guard let directory, height > 0 else { return nil }
        try file?.close(); file = nil
        let document = try LongScreenshotDocument(directory: directory, width: width, height: height, scale: scale)
        self.directory = nil
        previous = nil
        rollbackPixels = Data()
        return document
    }
}

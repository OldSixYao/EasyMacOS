import Foundation

/// 只比较纵向相交的文字，已完成的长图正文不参与后续分段查重。
struct ScreenshotTextAccumulator {
    private(set) var lines: [ScreenshotTextLine] = []
    private var keys: [String] = []
    private var buckets: [Int: Set<Int>] = [:]
    private let bucketHeight: CGFloat = 64

    init(lines: [ScreenshotTextLine] = []) {
        for line in lines { insert(line) }
    }

    mutating func append(_ additions: [ScreenshotTextLine]) {
        for line in additions {
            let key = normalized(line.text)
            guard !key.isEmpty else { continue }
            let candidates = bucketRange(line.rect).reduce(into: Set<Int>()) { $0.formUnion(buckets[$1] ?? []) }
            let matching = candidates.filter { matches(line, key: key, index: $0) }.max()
            if let index = matching {
                guard prefers(line, key: key, to: index) else { continue }
                for bucket in bucketRange(lines[index].rect) { buckets[bucket]?.remove(index) }
                lines[index] = line; keys[index] = key
                for bucket in bucketRange(line.rect) { buckets[bucket, default: []].insert(index) }
            } else { insert(line, key: key) }
        }
    }

    private func normalized(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private func bucketRange(_ rect: CGRect) -> ClosedRange<Int> {
        Int(floor(rect.minY / bucketHeight))...Int(floor(rect.maxY / bucketHeight))
    }
    private mutating func insert(_ line: ScreenshotTextLine, key: String? = nil) {
        let index = lines.count
        lines.append(line); keys.append(key ?? normalized(line.text))
        for bucket in bucketRange(line.rect) { buckets[bucket, default: []].insert(index) }
    }
    private func matches(_ line: ScreenshotTextLine, key: String, index: Int) -> Bool {
        let old = lines[index].rect, new = line.rect, intersection = old.intersection(new)
        guard !intersection.isNull else { return false }
        let smaller = min(old.width * old.height, new.width * new.height)
        guard smaller > 0 else { return false }
        if keys[index] == key { return intersection.width * intersection.height >= smaller * 0.5 }
        // 同一物理文字行在边界可能被截断或识别为不同字形，不能仅凭字符串相等查重。
        return intersection.width >= min(old.width, new.width) * 0.85
            && intersection.height >= min(old.height, new.height) * 0.7
            && abs(old.midY - new.midY) <= max(old.height, new.height) * 0.4
    }
    private func prefers(_ line: ScreenshotTextLine, key: String, to index: Int) -> Bool {
        let old = lines[index]
        if line.clipped != old.clipped { return !line.clipped }
        if key != keys[index] {
            if keys[index].contains(key) { return false }
            if key.contains(keys[index]) { return true }
        }
        return line.confidence > old.confidence
            || (line.confidence == old.confidence && line.rect.height > old.rect.height)
    }
}

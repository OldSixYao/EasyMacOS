import Foundation

/// 只保留像素、透明度和解色所需的块；不修改压缩流或重新计算块校验。
/// 解码与格式校验仍交给 ImageIO，本类型不解释图片像素。
enum PNGPixelData {
    private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let pixelChunks: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "sRGB", "gAMA", "cHRM", "iCCP", "sBIT",
        "cICP", "mDCV", "cLLI",
    ]
    private static let animationChunks: Set<String> = ["acTL", "fcTL", "fdAT"]

    static func sanitized(_ data: Data) -> Data? {
        guard data.starts(with: signature) else { return nil }
        var output = signature
        output.reserveCapacity(data.count)
        let firstChunk = data.startIndex + signature.count
        var cursor = firstChunk
        var hasPixels = false
        while cursor <= data.endIndex - 12 {
            let length = data[cursor..<cursor + 4].reduce(0) { $0 * 256 + Int($1) }
            guard length <= data.endIndex - cursor - 12,
                let type = String(data: data[cursor + 4..<cursor + 8], encoding: .ascii) else { return nil }
            let end = cursor + length + 12
            guard !animationChunks.contains(type) else { return nil }
            if pixelChunks.contains(type) {
                guard (cursor == firstChunk) == (type == "IHDR") else { return nil }
                output.append(data[cursor..<end])
            } else if data[cursor + 4] & 0x20 == 0 {
                // 未知关键块不能安全跳过，交给完整重编码路径处理。
                return nil
            }
            if type == "IDAT" { hasPixels = true }
            if type == "IEND" { return length == 0 && hasPixels ? output : nil }
            cursor = end
        }
        return nil
    }
}

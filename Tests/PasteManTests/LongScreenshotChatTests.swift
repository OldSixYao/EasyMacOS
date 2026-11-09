import AppKit
import ImageIO
import Testing
@testable import PasteMan

private func chatPage(height: Int = 3800) throws -> CGImage {
    let width = 1532
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.095, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    let texts = [
        "已取得当前窗口的滚动画面，正在检查连续内容。",
        "框选范围包含文章、段落间距和文件变更卡片。",
        "只有少量文字时，也应使用实际图像细节确认重叠。",
        "截图从当前位置开始，按实际位移保留新增像素。",
        "窗口保持原位，滚动结束后继续编辑长图。",
    ]
    for (index, y) in [340, 384, 428, 1500, 1544, 1588, 2450, 2494, 2538, 3300].enumerated() where y < height - 40 {
        ScreenshotRenderer.draw(ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 560, y: y)],
            color: AnnotationColor(red: 0.82, green: 0.82, blue: 0.82), width: 4,
            text: texts[index % texts.count] + " 第\(index + 1)段"), in: context)
    }
    for (index, y) in [640, 1820, 2810].enumerated() where y + 220 < height {
        let card = CGRect(x: 550, y: y, width: 930, height: 210)
        context.setFillColor(CGColor(gray: 0.13, alpha: 1)); context.fill(card)
        context.setStrokeColor(CGColor(gray: 0.22, alpha: 1)); context.stroke(card)
        for row in 0..<3 {
            ScreenshotRenderer.draw(ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 575, y: y + 20 + row * 60)],
                color: AnnotationColor(red: 0.6, green: 0.6, blue: 0.6), width: 4,
                text: ["Sources/Example/CaptureCoordinator.swift", "Sources/Example/ScrollingImage.swift", "展开其余文件 \(index + 4)"][row]), in: context)
        }
    }
    return try #require(context.makeImage())
}

@Suite("聊天页面长截屏匹配") struct LongScreenshotChatTests {
    @Test func sparseParagraphCannotBeMistakenForAnUnchangedBlankFrame() throws {
        let context = try #require(CGContext(data: nil, width: 1532, height: 1800, bitsPerComponent: 8,
            bytesPerRow: 1532 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1532, height: 1800))
        ScreenshotRenderer.draw(ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 560, y: 700)],
            color: AnnotationColor(red: 0.8, green: 0.8, blue: 0.8), width: 4,
            text: "只有这一段文字，也应保留小步滚动的实际位移。"), in: context)
        let page = try #require(context.makeImage())
        let first = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 1532, height: 1420)))
        let next = try #require(page.cropping(to: CGRect(x: 0, y: 40, width: 1532, height: 1420)))
        #expect(try LongScreenshotFeatures(first).match(LongScreenshotFeatures(next)).displacement == 40)
    }

    @Test func localizedTextAndLargeBlankRegionsDoNotRequireContentInEveryVerticalThird() throws {
        let page = try chatPage()
        for offset in [0, 220, 354, 990, 1200, 1800] {
            let first = try #require(page.cropping(to: CGRect(x: 0, y: offset, width: 1532, height: 1420)))
            let next = try #require(page.cropping(to: CGRect(x: 0, y: offset + 354, width: 1532, height: 1420)))
            #expect(try LongScreenshotFeatures(first).match(LongScreenshotFeatures(next)).displacement == 354)
        }
    }

    @Test func changingHoverCardDoesNotOverrideIndependentTextAlignment() throws {
        let page = try chatPage()
        let first = try #require(page.cropping(to: CGRect(x: 0, y: 1100, width: 1532, height: 1420)))
        let base = try #require(page.cropping(to: CGRect(x: 0, y: 1454, width: 1532, height: 1420)))
        let context = try #require(CGContext(data: nil, width: 1532, height: 1420, bitsPerComponent: 8,
            bytesPerRow: 1532 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(base, in: CGRect(x: 0, y: 0, width: 1532, height: 1420))
        context.setFillColor(CGColor(gray: 0.19, alpha: 1))
        context.fill(CGRect(x: 840, y: 500, width: 680, height: 300))
        let next = try #require(context.makeImage())
        #expect(try LongScreenshotFeatures(first).match(LongScreenshotFeatures(next)).displacement == 354)
    }

    @Test func consecutiveChatFramesAppendExactlyTheOriginalRows() async throws {
        let page = try chatPage()
        let stitcher = LongScreenshotStitcher(scale: 2)
        for offset in stride(from: 0, through: 2124, by: 354) {
            let frame = try #require(page.cropping(to: CGRect(x: 0, y: offset, width: 1532, height: 1420)))
            _ = try await stitcher.append(frame)
        }
        let document = try #require(try await stitcher.finish())
        #expect(document.image.height == 3544)
        let expected = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 1532, height: 3544)))
        let normalized = try ScreenshotRenderer.render(base: expected, pointSize: document.pointSize, annotations: [])
        let actualBytes = try #require(document.image.dataProvider?.data as Data?)
        let expectedBytes = try #require(normalized.dataProvider?.data as Data?)
        for row in 0..<3544 {
            let actualStart = row * document.image.bytesPerRow
            let expectedStart = row * normalized.bytesPerRow
            #expect(actualBytes.subdata(in: actualStart..<(actualStart + 1532 * 4))
                == expectedBytes.subdata(in: expectedStart..<(expectedStart + 1532 * 4)))
        }
    }
}

@Suite("聊天画面本地重放", .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_LONG_REPLAY_DIRECTORY"] != nil))
struct LongScreenshotChatReplayTests {
    @Test func sequentialFramesFromOneWindowMatchAndFinish() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["EASYMACOS_LONG_REPLAY_DIRECTORY"]))
        let count = Int(ProcessInfo.processInfo.environment["EASYMACOS_LONG_REPLAY_COUNT"] ?? "16") ?? 16
        var previous: LongScreenshotFeatures?
        let stitcher = LongScreenshotStitcher(scale: 2)
        var expectedHeight = 0
        for index in 0..<count {
            let source = try #require(CGImageSourceCreateWithURL(root.appendingPathComponent("frame-\(index).png") as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let current = try LongScreenshotFeatures(image)
            if let previous {
                let match = try previous.match(current)
                #expect(match.displacement == 354 || match.displacement == 0)
                expectedHeight += match.displacement
            } else { expectedHeight = image.height }
            let result = try await stitcher.append(image)
            #expect(result.height == expectedHeight)
            previous = current
        }
        let document = try #require(try await stitcher.finish())
        #expect(document.image.height == expectedHeight)
        print("同一聊天窗口连续 \(count) 帧重放成功，结果 \(document.image.width) × \(document.image.height)。")
    }
}

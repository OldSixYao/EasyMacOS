import AppKit
import ApplicationServices
import Synchronization

/// 同步辅助功能请求只在专用串行队列执行，跨线程仅传递查询参数和窗口元数据。
final class LongScreenshotAccessibilityReader: Sendable {
    struct Query: Sendable {
        let processID: pid_t
        let point: CGPoint
        let inspectFocus: Bool
    }
    struct Details: Sendable {
        var focusedFrame: CGRect?
        var hitProcessID: pid_t?
        var hitFrame: CGRect?
    }
    private let queue = DispatchQueue(label: "EasyMacOS.LongScreenshot.Accessibility", qos: .userInitiated)
    private let fetch: @Sendable (Query) -> Details

    init(fetch: @escaping @Sendable (Query) -> Details) { self.fetch = fetch }
    init(hitTest: @escaping @Sendable (AXUIElement, CGPoint) -> AXUIElement?) {
        fetch = { Self.fetch($0, hitTest: hitTest) }
    }

    func read(_ query: Query) async throws -> Details {
        let canceled = Mutex(false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let details: Details = try await withCheckedThrowingContinuation { continuation in
                queue.async { [fetch] in
                    guard !canceled.withLock({ $0 }) else { continuation.resume(throwing: CancellationError()); return }
                    let details = autoreleasepool { fetch(query) }
                    continuation.resume(returning: details)
                }
            }
            try Task.checkCancellation()
            return details
        } onCancel: { canceled.withLock { $0 = true } }
    }

    static func hitTest(_ root: AXUIElement, _ point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    private static func fetch(_ query: Query, hitTest: (AXUIElement, CGPoint) -> AXUIElement?) -> Details {
        let application = AXUIElementCreateApplication(query.processID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var details = Details()
        if query.inspectFocus {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                details.focusedFrame = frame(unsafeDowncast(focused, to: AXUIElement.self))
            }
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        // 系统级命中缺值时直接询问目标应用，保留原有兼容策略。
        let element = hitTest(system, query.point) ?? hitTest(application, query.point)
        var pid: pid_t = 0
        if let element, AXUIElementGetPid(element, &pid) == .success {
            details.hitProcessID = pid
            var window: CFTypeRef?
            if pid == query.processID,
                AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
                let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                details.hitFrame = frame(unsafeDowncast(window, to: AXUIElement.self))
            }
        }
        return details
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(window, 0.2)
        var position: CFTypeRef?, size: CFTypeRef?
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
            let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
            AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
            AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}

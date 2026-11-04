// Run against a launched, onboarded app: swift scripts/ui-smoke.swift
// Requires existing Accessibility access for the invoking terminal. Never requests it.
// Reads only window/focus metadata; does not read or modify clipboard content.
import AppKit
import ApplicationServices
import Carbon
import Foundation

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeFailure(description: message) }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    return condition()
}

func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attribute(element, name) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func menuItemCenter(_ app: AXUIElement) -> CGPoint? {
    guard let extras = attribute(app, kAXExtrasMenuBarAttribute),
        let items = attribute(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
        let item = items.first,
        let position = pointAttribute(item, kAXPositionAttribute),
        let sizeValue = attribute(item, kAXSizeAttribute)
    else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
}

func click(_ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func panelIsOnscreen(pid: pid_t) -> Bool {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    return windows.contains {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && ($0[kCGWindowLayer as String] as? Int) == Int(NSWindow.Level.floating.rawValue)
    }
}

func focusedWindowIsPanel(_ app: AXUIElement) -> Bool {
    guard let focused = attribute(app, kAXFocusedWindowAttribute) else { return false }
    return (attribute(focused as! AXUIElement, kAXRoleAttribute) as? String) == kAXWindowRole
}

do {
    try require(AXIsProcessTrusted(), "Accessibility access is required; no permission prompt was requested.")
    let bundleID = ProcessInfo.processInfo.environment["BUNDLE_ID"] ?? "app.pasteman.PasteMan"
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
    try require(apps.count == 1, "Run exactly one instance of EasyMacOS before this smoke test.")
    let app = apps[0]
    let element = AXUIElementCreateApplication(app.processIdentifier)
    let cursor = CGEvent(source: nil)?.location
    defer {
        if let cursor {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cursor, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
    for attempt in 1...3 {
        guard let point = menuItemCenter(element) else { throw SmokeFailure(description: "No status item found.") }
        click(point)
        try require(
            waitFor { panelIsOnscreen(pid: app.processIdentifier) }, "Click \(attempt): history never appeared.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try require(panelIsOnscreen(pid: app.processIdentifier), "Click \(attempt): history disappeared after opening.")
        try require(focusedWindowIsPanel(element), "Click \(attempt): history did not take keyboard focus.")
        print("PASS: left click \(attempt) opens a stable, focused history panel.")
        CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)?
            .postToPid(app.processIdentifier)
        CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)?
            .postToPid(app.processIdentifier)
        try require(waitFor { !panelIsOnscreen(pid: app.processIdentifier) }, "Escape did not dismiss history.")
        print("PASS: Escape dismisses history.")
    }
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}

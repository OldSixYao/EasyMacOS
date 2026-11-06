import AppKit
import FinderMenuCore
import Foundation
import SwiftUI
import Testing

@testable import PasteMan

/// 仅操作测试进程自己的离屏窗口，不安装事件接管或修改用户的鼠标偏好。
@Suite("鼠标参数界面", .serialized) @MainActor struct MouseScrollParameterViewTests {
    @Test func controlsSynchronizeValidateAndDisableInBothLanguages() async throws {
        guard ProcessInfo.processInfo.environment["EASYMACOS_MOUSE_UI"] == "1" else { return }
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let suite = "MouseScrollParameterView." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let service = MouseScrollService(hasPermission: { false }, observesWorkspace: false)
        let originalLanguage = L.language
        defer {
            defaults.removePersistentDomain(forName: suite)
            InterfaceLocalization.shared.setLanguage(originalLanguage)
        }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_MOUSE_UI_OUTPUT"]
                         ?? "/tmp/easymacos-mouse-parameters", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english] {
            InterfaceLocalization.shared.setLanguage(language)
            settings.mouse = .init()
            let hosting = NSHostingView(rootView: MouseSettingsView(
                settings: settings, service: service, permissions: PermissionService()))
            hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 540)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            func settle() async throws {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                hosting.layoutSubtreeIfNeeded()
            }
            // SwiftUI 的虚拟节点实现辅助功能方法，但未声明协议遵循，按选择器访问对象属性。
            func attribute(_ node: NSObject, _ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector) else { return nil }
                return node.perform(selector)?.takeUnretainedValue()
            }
            func descendants(_ node: NSObject, depth: Int = 0) -> [NSObject] {
                guard depth < 20 else { return [] }
                return [node] + (attribute(node, "accessibilityChildren") as? [NSObject] ?? []).flatMap {
                    descendants($0, depth: depth + 1)
                }
            }
            func control(_ identifier: String) throws -> NSObject {
                try #require(descendants(hosting).first {
                    attribute($0, "accessibilityIdentifier") as? String == identifier
                }, "未找到控件：\(identifier)")
            }
            func displayed(_ identifier: String) throws -> String {
                try #require(attribute(try control(identifier + ".value"), "accessibilityValue") as? String)
            }
            func submit(_ identifier: String, text: String) async throws {
                let node = try control(identifier + ".value")
                let field = try #require((node as? NSTextField) ?? (node as? NSTextFieldCell)?.controlView as? NSTextField)
                field.stringValue = text
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                try await settle()
                let action = try #require(field.action)
                #expect(field.sendAction(action, to: field.target))
                try await settle()
            }
            try await settle()
            #expect(try displayed("mouse.minimumStep") == "33.60")
            #expect(try displayed("mouse.speed") == "1.00")
            #expect(try displayed("mouse.duration") == "1.80")
            for (identifier, range) in [("mouse.minimumStep", 0.01...100.0), ("mouse.speed", 0.5...10.0),
                                        ("mouse.duration", 1.0...5.0)] {
                let slider = try control(identifier + ".slider")
                #expect((attribute(slider, "accessibilityMinValue") as? NSNumber)?.doubleValue == range.lowerBound)
                #expect((attribute(slider, "accessibilityMaxValue") as? NSNumber)?.doubleValue == range.upperBound)
                _ = try control(identifier + ".stepper")
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                hosting.appearance = NSAppearance(named: appearance)
                window.appearance = hosting.appearance
                try await settle()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let mode = appearance == .aqua ? "light" : "dark"
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: output.appendingPathComponent("mouse-\(language.rawValue)-\(mode).png"))
            }
            let gain = try control("mouse.speed.slider")
            (gain as AnyObject).setAccessibilityValue?(3.76)
            try await settle()
            #expect(settings.mouse.speed == 3.76)
            #expect(try displayed("mouse.speed") == "3.76")
            // 离屏窗口不接受系统按压动作，直接触发原生控件的步进和目标动作。
            let stepper = try #require((try control("mouse.speed.stepper") as? NSStepperCell)?.controlView as? NSStepper)
            stepper.doubleValue += stepper.increment
            let stepAction = try #require(stepper.action)
            #expect(stepper.sendAction(stepAction, to: stepper.target))
            try await settle()
            #expect(abs(settings.mouse.speed - 3.77) < 0.000_001)
            #expect(try displayed("mouse.speed") == "3.77")
            for (identifier, text, expected) in [
                ("mouse.minimumStep", "0.001", "0.01"), ("mouse.minimumStep", "200", "100.00"),
                ("mouse.minimumStep", "无效输入", "33.60"), ("mouse.speed", "0", "0.50"),
                ("mouse.speed", "20", "10.00"), ("mouse.speed", "nan", "1.00"),
                ("mouse.speed", "3.765", "3.77"), ("mouse.duration", "0.08", "1.00"),
                ("mouse.duration", "6", "5.00"), ("mouse.duration", "inf", "1.80"),
                ("mouse.duration", "2.61", "2.61")
            ] {
                try await submit(identifier, text: text)
                #expect(try displayed(identifier) == expected)
            }
            #expect(abs(settings.mouse.minimumStep - 33.6) < 0.000_001)
            #expect(abs(settings.mouse.speed - 3.77) < 0.000_001)
            #expect(AppSettings(defaults: defaults).mouse == settings.mouse)
            settings.mouse.durationLevel = 2.61
            try await settle()
            #expect(try displayed("mouse.duration") == "2.61")
            #expect(abs(settings.mouse.duration - 0.261) < 0.000_001)
            settings.mouse.smooth = false
            try await settle()
            for suffix in [".slider", ".value", ".stepper"] {
                let stepEnabled = (try control("mouse.minimumStep" + suffix) as AnyObject).isAccessibilityEnabled?()
                let durationEnabled = (try control("mouse.duration" + suffix) as AnyObject).isAccessibilityEnabled?()
                let gainEnabled = (try control("mouse.speed" + suffix) as AnyObject).isAccessibilityEnabled?()
                #expect(stepEnabled == false)
                #expect(durationEnabled == false)
                #expect(gainEnabled == true)
            }
            let reset: AnyObject = try control("mouse.restoreDefaults")
            let resetPressed = reset.accessibilityPerformPress?()
            #expect(resetPressed == true)
            try await settle()
            #expect(settings.mouse == .init())
            #expect(try displayed("mouse.minimumStep") == "33.60")
            #expect(try displayed("mouse.speed") == "1.00")
            #expect(try displayed("mouse.duration") == "1.80")
        }
    }
}

import AppKit
import SwiftUI

struct ScreenshotTextOptions: View {
    @Bindable var state: ScreenshotEditorState
    private static let families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L.t("Font", "字体"))
                Picker(L.t("Font", "字体"), selection: $state.textStyle.fontFamily) {
                    ForEach(Self.families, id: \.self) { family in Text(family).tag(family) }
                }.labelsHidden().pickerStyle(.menu).buttonStyle(.bordered).frame(width: 170)
                    .accessibilityIdentifier("screenshot.text.font")
                Text(L.t("Size", "字号"))
                TextField(L.t("Font size", "字号"), value: Binding<Double>(get: { Double(state.textStyle.resolvedSize) },
                    set: { state.textStyle.fontSize = $0.isFinite ? CGFloat(min(512, max(6, $0))) : 24 }),
                    format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                    .accessibilityIdentifier("screenshot.text.fontSize")
                Stepper(L.t("Font size", "字号"), value: $state.textStyle.fontSize, in: 6...512, step: 1)
                    .labelsHidden().fixedSize()
                Divider().frame(height: 20)
                attribute("bold", title: L.t("Bold", "加粗"), selected: state.textStyle.isBold) { state.textStyle.isBold.toggle() }
                    .accessibilityIdentifier("screenshot.text.bold")
                attribute("italic", title: L.t("Italic", "斜体"), selected: state.textStyle.isItalic) { state.textStyle.isItalic.toggle() }
                    .accessibilityIdentifier("screenshot.text.italic")
                Spacer(minLength: 0)
            }.frame(height: 36)
            HStack(spacing: 12) {
                Text(L.t("Text color", "文字颜色"))
                ForEach(AnnotationColor.palette.indices, id: \.self) { index in
                    let color = AnnotationColor.palette[index]
                    Button { state.textColor = color } label: {
                        Circle().fill(Color(red: color.red, green: color.green, blue: color.blue))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(state.textColor == color ? ScreenshotToolbar.tint : .gray.opacity(0.5),
                                lineWidth: state.textColor == color ? 2 : 1).padding(-3))
                    }.accessibilityLabel(L.t("Text color", "文字颜色") + " \(index + 1)")
                }
                Text(L.t("Custom color", "自定颜色"))
                ScreenshotTextColorWell(color: $state.textColor)
                    .frame(width: 24, height: 24).accessibilityIdentifier("screenshot.text.color")
                Spacer(minLength: 0)
            }.frame(height: 36)
        }.font(.system(size: 12)).padding(.horizontal, 16)
    }
    private func attribute(_ symbol: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28)
                .foregroundStyle(selected ? ScreenshotToolbar.tint : .primary)
                .background(selected ? ScreenshotToolbar.tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.help(title).accessibilityLabel(title)
    }
}

private struct ScreenshotTextColorWell: NSViewRepresentable {
    @Binding var color: AnnotationColor
    func makeNSView(context: Context) -> ScreenshotTextColorWellView {
        let well = ScreenshotTextColorWellView()
        well.colorWellStyle = .minimal
        well.target = well; well.action = #selector(ScreenshotTextColorWellView.changed)
        return well
    }
    func updateNSView(_ well: ScreenshotTextColorWellView, context: Context) {
        well.color = NSColor(cgColor: color.cgColor) ?? .systemRed
        well.setAccessibilityLabel(L.t("Custom text color", "自定文字颜色"))
        well.onChange = { value in
            guard let value = value.usingColorSpace(.sRGB) else { return }
            color = AnnotationColor(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent)
        }
    }
    static func dismantleNSView(_ well: ScreenshotTextColorWellView, coordinator: ()) {
        if well.isActive { NSColorPanel.shared.close() }
        well.deactivate(); well.onChange = nil
    }
}

/// 系统颜色面板必须高于冻结截图浮层，工具退出时恢复其原有层级。
@MainActor private final class ScreenshotTextColorWellView: NSColorWell {
    var onChange: ((NSColor) -> Void)?
    private var previousPanelSettings: (level: NSWindow.Level, showsAlpha: Bool)?
    @objc func changed() { onChange?(color) }
    override func activate(_ exclusive: Bool) {
        super.activate(exclusive)
        guard previousPanelSettings == nil else { return }
        let panel = NSColorPanel.shared
        previousPanelSettings = (panel.level, panel.showsAlpha)
        panel.showsAlpha = false
        panel.level = NSWindow.Level(rawValue: max(window?.level.rawValue ?? 0, NSWindow.Level.floating.rawValue) + 1)
        panel.orderFrontRegardless()
    }
    override func deactivate() {
        super.deactivate()
        if let settings = previousPanelSettings {
            NSColorPanel.shared.level = settings.level; NSColorPanel.shared.showsAlpha = settings.showsAlpha
        }
        previousPanelSettings = nil
    }
}

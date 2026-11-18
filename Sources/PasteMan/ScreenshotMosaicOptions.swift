import SwiftUI

struct ScreenshotMosaicOptionsView: View {
    @Bindable var state: ScreenshotEditorState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ForEach(ScreenshotMosaicMode.allCases, id: \.self) { mode in
                    Button { state.mosaicOptions.mode = mode } label: {
                        Label(mode.title, systemImage: mode.symbol).frame(width: 66, height: 28)
                            .foregroundStyle(state.mosaicOptions.mode == mode ? ScreenshotToolbar.tint : .primary)
                            .background(state.mosaicOptions.mode == mode ? ScreenshotToolbar.tint.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    }.modifier(ScreenshotHoverFeedback(title: mode.title, state: state))
                        .accessibilityIdentifier("screenshot.mosaic." + mode.rawValue)
                }
                Divider().frame(height: 20)
                Text(L.t("Block size", "颗粒大小"))
                Slider(value: $state.mosaicOptions.blockSize, in: 4...40, step: 1)
                    .frame(width: 150).accessibilityLabel(L.t("Block size", "颗粒大小"))
                    .modifier(ScreenshotHoverFeedback(title: L.t("Block size", "颗粒大小"), state: state))
                    .accessibilityIdentifier("screenshot.mosaic.blockSize")
                Text("\(Int(state.mosaicOptions.resolvedBlockSize))").monospacedDigit().frame(width: 30, alignment: .trailing)
                Spacer(minLength: 0)
            }.frame(height: 36)
            if state.mosaicOptions.mode == .brush {
                HStack(spacing: 10) {
                    Text(L.t("Brush size", "画笔大小"))
                    Slider(value: $state.mosaicOptions.brushSize, in: 8...160, step: 1)
                        .frame(width: 240).accessibilityLabel(L.t("Brush size", "画笔大小"))
                        .modifier(ScreenshotHoverFeedback(title: L.t("Brush size", "画笔大小"), state: state))
                        .accessibilityIdentifier("screenshot.mosaic.brushSize")
                    Text("\(Int(state.mosaicOptions.resolvedBrushSize))").monospacedDigit().frame(width: 30, alignment: .trailing)
                    Spacer(minLength: 0)
                }.frame(height: 36)
            }
        }.font(.system(size: 12)).padding(.horizontal, 16)
    }
}

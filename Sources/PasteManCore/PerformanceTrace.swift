import os

/// 只记录阶段和耗时，不记录剪贴板内容、文件路径或来源应用。
public enum PerformanceTrace {
    public static let signposter = OSSignposter(subsystem: "app.pasteman.PasteMan", category: "Performance")
}

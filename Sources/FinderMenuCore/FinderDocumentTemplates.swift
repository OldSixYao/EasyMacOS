import Foundation

public enum FinderDocumentTemplates {
    private final class ResourceMarker {}

    private static var bundledDirectory: URL? {
        // 避免资源包丢失时包管理器生成的 Bundle.module 直接终止进程。
        let moduleBundle = Bundle(for: ResourceMarker.self)
        var candidates = [Bundle.main.resourceURL, moduleBundle.resourceURL, Bundle.main.bundleURL]
        // 原生包测试把资源放在测试包旁边；独立应用只从自身资源读取。
        for bundle in [moduleBundle, Bundle.main] where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent())
        }
        return candidates.compactMap { candidate -> URL? in
            guard let bundleURL = candidate?.appendingPathComponent("EasyMacOS_FinderMenuCore.bundle", isDirectory: true) else { return nil }
            let resourceURL = Bundle(url: bundleURL)?.resourceURL ?? bundleURL
            let directory = resourceURL.appendingPathComponent("OfficeTemplates", isDirectory: true)
            return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
        }.first
    }

    public static func data(for suffix: String, resourceDirectory: URL? = nil) throws -> Data {
        guard FinderConfiguration.officeSuffixes.contains(suffix) else { return Data() }
        let url = (resourceDirectory ?? bundledDirectory)?.appendingPathComponent("blank." + suffix)
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw FinderMenuError.templateUnavailable
        }
        return data
    }
}

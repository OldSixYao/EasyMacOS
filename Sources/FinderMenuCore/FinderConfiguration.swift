import Darwin
import Foundation

public struct FinderFileType: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let suffix: String

    public static func normalize(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix(".") { value.removeFirst() }
        value = value.lowercased()
        guard !value.isEmpty, !value.split(separator: ".", omittingEmptySubsequences: false).contains(""),
            !value.contains("/"), !value.contains("\\"), !value.contains(":"),
            value.unicodeScalars.allSatisfy({
                !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
            }), (try? FinderOperations.validateName("未命名 \(Int.max)." + value)) != nil
        else { throw FinderMenuError.invalidFileType }
        return value
    }
}

public struct FinderConfiguration: Codable, Equatable, Sendable {
    public static let defaultSuffixes = ["txt", "json", "xml", "md", "csv", "html", "css", "js"]
    // 留出普通动作标识，限制在系统跨进程菜单可保留的有符号整型范围内。
    public static let maximumFileTypeID = (Int(Int32.max) - 1025) / 2
    public var disabledActions: Set<String>
    public var enabled: Bool
    public var language: AppLanguage?
    public private(set) var fileTypes: [FinderFileType]
    public private(set) var nextFileTypeID: Int

    public init(disabledActions: Set<String> = [], enabled: Bool = true) {
        self.disabledActions = disabledActions
        self.enabled = enabled
        language = nil
        fileTypes = Self.defaultSuffixes.enumerated().map { FinderFileType(id: $0.offset + 1, suffix: $0.element) }
        nextFileTypeID = fileTypes.count + 1
    }

    private enum CodingKeys: String, CodingKey { case disabledActions, enabled, fileTypes, nextFileTypeID, language }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(disabledActions: try values.decode(Set<String>.self, forKey: .disabledActions),
                  enabled: try values.decode(Bool.self, forKey: .enabled))
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language)
        if values.contains(.fileTypes) {
            fileTypes = try values.decode([FinderFileType].self, forKey: .fileTypes)
            nextFileTypeID = try values.decode(Int.self, forKey: .nextFileTypeID)
        }
        guard nextFileTypeID > 0, nextFileTypeID <= Self.maximumFileTypeID + 1,
            Set(fileTypes.map(\.id)).count == fileTypes.count,
            Set(fileTypes.map(\.suffix)).count == fileTypes.count,
            fileTypes.allSatisfy({ $0.id > 0 && $0.id < nextFileTypeID && (try? FinderFileType.normalize($0.suffix)) == $0.suffix })
        else { throw FinderMenuError.invalidFileType }
    }

    public mutating func addFileType(_ input: String) throws {
        let suffix = try FinderFileType.normalize(input)
        guard !fileTypes.contains(where: { $0.suffix == suffix }) else { return }
        guard nextFileTypeID <= Self.maximumFileTypeID else { throw FinderMenuError.invalidFileType }
        fileTypes.append(FinderFileType(id: nextFileTypeID, suffix: suffix))
        nextFileTypeID += 1
    }

    public mutating func removeFileType(id: Int) { fileTypes.removeAll { $0.id == id } }

    public mutating func restoreDefaults() throws {
        disabledActions = []
        enabled = true
        let previous = fileTypes
        fileTypes = []
        for suffix in Self.defaultSuffixes {
            if let existing = previous.first(where: { $0.suffix == suffix }) { fileTypes.append(existing) }
            else { try addFileType(suffix) }
        }
    }

    public func contains(_ action: FinderAction) -> Bool {
        enabled && !disabledActions.contains(action.rawValue)
    }

    public mutating func set(_ action: FinderAction, enabled: Bool) {
        if enabled { disabledActions.remove(action.rawValue) } else { disabledActions.insert(action.rawValue) }
    }
}

/// The sandboxed extension has a read-only exception for this app-owned configuration directory.
public struct FinderConfigurationStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url =
            url ?? Self.accountHome.appendingPathComponent("Library/Application Support/EasyMacOS/finder-menu.json")
    }

    public func load() throws -> FinderConfiguration {
        do {
            return try JSONDecoder().decode(FinderConfiguration.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return FinderConfiguration()
        }
    }

    public func save(_ configuration: FinderConfiguration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    private static var accountHome: URL {
        // Foundation's home and application-support URLs point inside the extension's sandbox.
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let path = buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(getuid(), &record, storage.baseAddress, storage.count, &result) == 0,
                result != nil, let directory = record.pw_dir
            else { return nil }
            return String(cString: directory)
        }
        return URL(fileURLWithPath: path ?? NSHomeDirectory(), isDirectory: true)
    }
}

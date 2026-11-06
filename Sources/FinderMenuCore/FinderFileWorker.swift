import Foundation

/// 文件元数据与创建操作不占用宿主应用的主线程。
public actor FinderFileWorker {
    public static let shared = FinderFileWorker()
    public func directory(for items: [URL]) throws -> URL { try FinderOperations.directory(for: items) }
    public func create(suffix: String, items: [URL]) throws -> URL {
        try Task.checkCancellation()
        return try FinderOperations.createFile(suffix: suffix, in: FinderOperations.directory(for: items))
    }
    public func validateSources(_ items: [URL]) throws -> [URL] { try FinderMoveValidation.sources(items) }
    public func validateDestination(_ directory: URL, items: [URL]) throws {
        try Task.checkCancellation()
        try FinderMoveValidation.destination(directory, for: items)
    }
}

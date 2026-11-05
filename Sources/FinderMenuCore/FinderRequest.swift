import Foundation

public struct FinderRequest: Equatable, Sendable {
    public static let scheme = "easymacos"
    public static let settingsURL = URL(string: "easymacos://finder-settings")!
    public let action: FinderAction
    public let items: [URL]
    public let suffix: String?
    public let cutToken: UUID?

    public init(action: FinderAction, items: [URL], suffix: String? = nil, cutToken: UUID? = nil) throws {
        guard (action == .pasteMove) == (cutToken != nil) else { throw FinderMenuError.invalidRequest }
        if let suffix {
            guard action == .newText, (try? FinderFileType.normalize(suffix)) == suffix
            else { throw FinderMenuError.invalidRequest }
        }
        guard !items.isEmpty, items.count <= 1_000,
            items.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0") })
        else { throw FinderMenuError.invalidRequest }
        self.suffix = suffix
        self.cutToken = cutToken
        self.action = action
        self.items = items.map(\.standardizedFileURL)
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == Self.scheme, components.host == "finder",
            components.user == nil, components.password == nil, components.port == nil,
            components.path.isEmpty, components.fragment == nil,
            let queries = components.queryItems,
            queries.allSatisfy({ ["action", "path", "suffix", "cutToken"].contains($0.name) }),
            queries.filter({ $0.name == "cutToken" }).count <= 1,
            queries.filter({ $0.name == "suffix" }).count <= 1,
            queries.filter({ $0.name == "suffix" }).allSatisfy({ $0.value != nil }),
            queries.filter({ $0.name == "action" }).count == 1,
            let raw = queries.first(where: { $0.name == "action" })?.value,
            let action = FinderAction(rawValue: raw)
        else { throw FinderMenuError.invalidRequest }
        let paths = queries.filter { $0.name == "path" }
        let tokenQuery = queries.first(where: { $0.name == "cutToken" })
        let token = tokenQuery?.value.flatMap(UUID.init(uuidString:))
        guard tokenQuery == nil || token != nil else { throw FinderMenuError.invalidRequest }
        guard paths.allSatisfy({ $0.value?.hasPrefix("/") == true && $0.value?.contains("\0") == false })
        else { throw FinderMenuError.invalidRequest }
        try self.init(action: action, items: paths.compactMap(\.value).map { URL(fileURLWithPath: $0) },
                      suffix: queries.first(where: { $0.name == "suffix" })?.value, cutToken: token)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "finder"
        components.queryItems =
            [URLQueryItem(name: "action", value: action.rawValue)]
            + items.map { URLQueryItem(name: "path", value: $0.path) }
        if let suffix { components.queryItems?.append(URLQueryItem(name: "suffix", value: suffix)) }
        if let cutToken { components.queryItems?.append(URLQueryItem(name: "cutToken", value: cutToken.uuidString)) }
        return components.url!
    }
}

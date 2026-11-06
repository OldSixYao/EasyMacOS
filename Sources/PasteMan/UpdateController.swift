import AppKit
import Foundation
import Observation
import Sparkle

@MainActor protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

@MainActor protocol UpdateEngine: AnyObject {
    func start() throws
    func checkForUpdates()
}

/// 三个入口共用一个会话；首次点击前不初始化更新器，也不进行网络请求。
@MainActor @Observable final class UpdateController: NSObject, UpdateChecking, SPUUpdaterDelegate {
    private(set) var isChecking = false
    var canCheckForUpdates: Bool { !isChecking }
    @ObservationIgnored private var engine: (any UpdateEngine)?
    @ObservationIgnored private let makeEngine: @MainActor (any SPUUpdaterDelegate) -> any UpdateEngine
    @ObservationIgnored private let availability: @MainActor () async throws -> Bool
    @ObservationIgnored private let present: @MainActor (UpdateFeedback) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        makeEngine: @escaping @MainActor (any SPUUpdaterDelegate) -> any UpdateEngine = { SparkleUpdateEngine(delegate: $0) },
        availability: @escaping @MainActor () async throws -> Bool = { try await UpdateAvailability.check() },
        present: @escaping @MainActor (UpdateFeedback) -> Void = { UpdateUserDriver.present($0) }
    ) {
        self.makeEngine = makeEngine
        self.availability = availability
        self.present = present
        super.init()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        isChecking = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                guard try await availability() else {
                    present(.unpublished)
                    isChecking = false
                    return
                }
                if engine == nil {
                    let candidate = makeEngine(self)
                    try candidate.start()
                    engine = candidate
                }
                engine?.checkForUpdates()
            } catch {
                present(.failure(error))
                isChecking = false
            }
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // 即使旧偏好曾启用自动检查，也只接受用户发起的更新会话。
        guard updateCheck == .updates else { throw CancellationError() }
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
    ) {
        isChecking = false
    }
}

enum UpdateAvailability {
    static let feedURL = URL(string: "https://github.com/OldSixYao/EasyMacOS/releases/latest/download/appcast.xml")!

    /// 首个版本尚未发布时，区分清单不存在与网络故障；不把其他故障误报为已是最新版。
    static func check(url: URL = feedURL, session: URLSession = .shared) async throws -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 404 { return false }
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return true
    }
}

@MainActor final class SparkleUpdateEngine: UpdateEngine {
    let updater: SPUUpdater
    let userDriver: UpdateUserDriver

    init(delegate: any SPUUpdaterDelegate, bundle: Bundle = .main) {
        userDriver = UpdateUserDriver()
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: delegate)
    }

    func start() throws {
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        try updater.start()
    }

    func checkForUpdates() { updater.checkForUpdates() }
}

struct UpdateFeedback {
    let title: String
    let message: String

    static var unpublished: Self {
        Self(title: L.t("No releases available", "暂时没有可用版本"), message: L.t(
            "No update has been published yet. Please try again later.", "尚未发布可供下载的更新，请稍后再试。"))
    }

    static func failure(_ error: any Error) -> Self {
        let nsError = error as NSError
        var underlying = nsError
        for _ in 0..<8 {
            guard let next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            underlying = next
        }
        let network = nsError.domain == NSURLErrorDomain || underlying.domain == NSURLErrorDomain
            || (nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.downloadError.rawValue)
        return Self(title: L.t("Update unavailable", "无法更新"), message: network
            ? L.t("Could not reach the update server. Check your connection and try again.", "无法连接更新服务器，请检查网络后重试。")
            : L.t("The update could not be verified or installed. Your current application has been preserved. Please try again later.",
                  "无法验证或安装更新，当前应用已保留，请稍后重试。"))
    }
}

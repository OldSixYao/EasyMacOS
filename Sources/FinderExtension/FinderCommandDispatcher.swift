import FinderMenuCore

/// 系统从后台消息队列回调；只把可发送的请求值交给主线程。
struct FinderCommandDispatcher: Sendable {
    let perform: @MainActor @Sendable (FinderRequest) -> Void

    func submit(_ request: FinderRequest) {
        Task { @MainActor in perform(request) }
    }
}

import Foundation

/// 活跃输入期间短暂复用权限结果；闲置时没有轮询，恢复接管时必须强制复核。
struct MouseScrollPermissionGate {
    private var checkedAt: TimeInterval?
    private var allowed = false
    private let lifetime: TimeInterval = 0.1

    mutating func allows(at time: TimeInterval, force: Bool = false, check: () -> Bool) -> Bool {
        guard time.isFinite else { return false }
        let expired = checkedAt.map { time < $0 || time - $0 >= lifetime } ?? true
        if force || expired {
            allowed = check()
            checkedAt = time
        }
        return allowed
    }
}

struct MouseScrollConfiguration: Codable, Equatable, Sendable {
    static let minimumStepRange = 0.01...100.0
    static let speedRange = 0.5...10.0
    static let durationLevelRange = 1.0...5.0

    var enabled = false
    var smooth = true
    var reversed = false
    var minimumStep = 33.6
    var speed = 1.0
    var duration = 0.18
    var excludedApps: Set<String> = []
    var remoteCompatibility = false

    var normalized: Self {
        var result = self
        result.minimumStep = minimumStep.isFinite
            ? min(Self.minimumStepRange.upperBound, max(Self.minimumStepRange.lowerBound, minimumStep)) : 33.6
        result.speed = speed.isFinite ? min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, speed)) : 1
        result.duration = duration.isFinite
            ? min(Self.durationLevelRange.upperBound / 10, max(Self.durationLevelRange.lowerBound / 10, duration)) : 0.18
        return result
    }

    /// 界面使用无单位档位，偏好与动画继续使用秒，避免改变旧配置的单位。
    var durationLevel: Double {
        get { duration * 10 }
        set { duration = newValue / 10 }
    }

    var multiplier: Double { normalized.speed * (reversed ? -1 : 1) }

    private enum CodingKeys: String, CodingKey {
        case enabled, smooth, reversed, minimumStep, speed, duration, excludedApps, remoteCompatibility
    }
}

extension MouseScrollConfiguration {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        smooth = try values.decodeIfPresent(Bool.self, forKey: .smooth) ?? true
        reversed = try values.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        minimumStep = try values.decodeIfPresent(Double.self, forKey: .minimumStep) ?? 33.6
        speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0.18
        excludedApps = try values.decodeIfPresent(Set<String>.self, forKey: .excludedApps) ?? []
        remoteCompatibility = try values.decodeIfPresent(Bool.self, forKey: .remoteCompatibility) ?? false
    }
}

struct MouseScrollVector: Equatable, Sendable {
    var x = 0.0
    var y = 0.0
    static let zero = Self()
    var isZero: Bool { x == 0 && y == 0 }
}

struct MouseScrollInput: Sendable {
    var delta = MouseScrollVector()
    var targetPID: Int32 = 0
    var targetWindow: Int64 = 0
    var targetBundleID: String?
    var flags: UInt64 = 0
    var continuous = false
    var hasPhase = false
    var hasOtherAxis = false
    var generated = false
    var commandOrControl = false

    var context: Context { Context(pid: targetPID, window: targetWindow, flags: flags) }
    struct Context: Equatable, Sendable {
        let pid: Int32
        let window: Int64
        let flags: UInt64
    }
}

/// 独立于系统事件和真实时钟，便于验证直通策略与累计位移。
struct MouseScrollProcessor {
    enum Disposition: Equatable { case passThrough, immediate, smooth }
    private(set) var configuration: MouseScrollConfiguration
    private let ownPID: Int32
    private(set) var context: MouseScrollInput.Context?
    private var horizontal = SmoothAxis()
    private var vertical = SmoothAxis()

    init(configuration: MouseScrollConfiguration, ownPID: Int32) {
        self.configuration = configuration.normalized
        self.ownPID = ownPID
    }

    var hasPending: Bool { horizontal.hasPending || vertical.hasPending }

    mutating func configure(_ configuration: MouseScrollConfiguration) {
        cancel()
        self.configuration = configuration.normalized
    }

    mutating func cancel() {
        context = nil
        horizontal = SmoothAxis()
        vertical = SmoothAxis()
    }

    mutating func receive(_ input: MouseScrollInput, at time: TimeInterval) -> Disposition {
        // 回注事件可能再次经过接管点；不能让它清除仍未完成的动画。
        if input.generated { return .passThrough }
        guard configuration.enabled, (!input.continuous || configuration.remoteCompatibility), !input.hasPhase,
            !input.hasOtherAxis, !input.commandOrControl,
            input.targetPID > 0, input.targetPID != ownPID,
            let bundleID = input.targetBundleID, !bundleID.isEmpty,
            !configuration.excludedApps.contains(bundleID),
            input.delta.x.isFinite, input.delta.y.isFinite,
            abs(input.delta.x) <= 1_000_000, abs(input.delta.y) <= 1_000_000,
            !input.delta.isZero, time.isFinite
        else {
            cancel()
            return .passThrough
        }
        if context != input.context { cancel() }
        context = input.context
        guard configuration.smooth else { return .immediate }
        // 每轴先补足单次输入的最短距离，再应用速度和反向；零轴不产生额外滚动。
        func enhanced(_ delta: Double) -> Double {
            guard delta != 0 else { return 0 }
            let magnitude = max(abs(delta), configuration.minimumStep)
            return (delta < 0 ? -magnitude : magnitude) * configuration.multiplier
        }
        horizontal.add(enhanced(input.delta.x), at: time)
        vertical.add(enhanced(input.delta.y), at: time)
        return .smooth
    }

    mutating func sample(at time: TimeInterval) -> MouseScrollVector {
        MouseScrollVector(
            x: horizontal.sample(at: time, duration: configuration.duration),
            y: vertical.sample(at: time, duration: configuration.duration))
    }
}

private struct SmoothAxis {
    private var start = 0.0
    private var position = 0.0
    private var target = 0.0
    private var startedAt = 0.0
    private var fraction = 0.0
    private var distance = 0.0
    var hasPending: Bool { position != target }

    mutating func add(_ delta: Double, at time: TimeInterval) {
        guard delta != 0 else { return }
        let remaining = target - position
        if delta * remaining < 0 || (remaining == 0 && delta * fraction < 0) {
            self = SmoothAxis()
        }
        start = position
        target += delta
        distance = abs(target - start)
        startedAt = time
    }

    mutating func sample(at time: TimeInterval, duration: TimeInterval) -> Double {
        guard hasPending, time.isFinite else { return 0 }
        // 小位移按距离缩短响应时间，所有应用始终输出同一种平滑像素事件。
        // 使用连续曲线避免在某个输入阈值突然切换为原生步进，时长不超过用户设置。
        let response = max(1 / 60.0, duration * min(1, sqrt(distance / 80)))
        let progress = min(1, max(0, (time - startedAt) / response))
        let next = progress == 1 ? target : start + (target - start) * (1 - pow(1 - progress, 3))
        let value = next - position + fraction
        let pixels = value.rounded(.towardZero)
        fraction = value - pixels
        position = next
        if progress == 1 {
            start = 0
            position = 0
            target = 0
        }
        return pixels
    }
}

/// 非平滑模式下，原生整数字段也保留不足一个单位的余量。
struct MouseScrollQuantizer {
    private var fraction = 0.0
    private var direction = 0.0

    mutating func scale(_ value: Int64, by multiplier: Double) -> Int64 {
        guard value != 0 else { return 0 }
        let scaled = Double(value) * multiplier
        let sign = scaled.sign == .minus ? -1.0 : 1.0
        if sign != direction { fraction = 0 }
        direction = sign
        let total = scaled + fraction
        // 系统事件字段是有符号整数，异常输入不能使转换溢出。
        let integral = min(Double(Int32.max), max(Double(Int32.min), total.rounded(.towardZero)))
        fraction = abs(total) <= Double(Int32.max) ? total - integral : 0
        return Int64(integral)
    }
}

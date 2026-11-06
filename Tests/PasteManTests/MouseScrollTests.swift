import AppKit
import Foundation
import Testing

@testable import PasteMan

// 距离守恒用例显式关闭步长放大；默认 33.60 的行为由专门的保底用例覆盖。
private func enabledMouse(smooth: Bool = true, reversed: Bool = false, speed: Double = 1,
                          minimumStep: Double = 0.01) -> MouseScrollConfiguration {
    var configuration = MouseScrollConfiguration()
    configuration.enabled = true
    configuration.smooth = smooth
    configuration.reversed = reversed
    configuration.speed = speed
    configuration.minimumStep = minimumStep
    return configuration
}

private func wheel(x: Double = 0, y: Double = 40) -> MouseScrollInput {
    MouseScrollInput(delta: MouseScrollVector(x: x, y: y), targetPID: 12345,
                     targetWindow: 91, targetBundleID: "test.scroll")
}

@Suite("鼠标滚动计算") struct MouseScrollEngineTests {
    @Test func defaultMinimumStepAmplifiesSmallInputsAndKeepsFractionalRemainders() {
        var configuration = MouseScrollConfiguration()
        configuration.enabled = true
        #expect(configuration.minimumStep == 33.6)
        var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
        var total = 0.0
        for index in 0..<10 {
            #expect(processor.receive(wheel(y: 8), at: Double(index)) == .smooth)
            let output = processor.sample(at: Double(index) + 0.5)
            #expect(output.x == 0)
            total += output.y
            #expect(!processor.hasPending)
        }
        #expect(abs(total - 336) < 1)
    }

    @Test func minimumStepIsAppliedPerNonzeroAxisBeforeGainAndReversal() {
        for minimumStep in [0.01, 20, 33.6, 100] {
            for speed in [0.5, 1, 2.2, 10] {
                for reversed in [false, true] {
                    for distance in [0, 0.001, minimumStep / 2, minimumStep, minimumStep * 2] {
                        for direction in [-1.0, 1] {
                            let configuration = enabledMouse(reversed: reversed, speed: speed, minimumStep: minimumStep)
                            var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
                            #expect(processor.receive(wheel(x: -direction * distance, y: direction * 200), at: 0) == .smooth)
                            let output = processor.sample(at: 1)
                            let expectedX = distance == 0 ? 0 : -direction * max(distance, minimumStep) * configuration.multiplier
                            #expect(abs(output.x - expectedX) < 1)
                            #expect(abs(output.y - direction * 200 * configuration.multiplier) < 1)
                        }
                    }
                }
            }
        }
        var processor = MouseScrollProcessor(configuration: enabledMouse(minimumStep: 20), ownPID: 42)
        _ = processor.receive(wheel(y: 8), at: 0)
        #expect(processor.sample(at: 1) == MouseScrollVector(y: 20))
    }

    @Test func largestGainStepAndDurationAccumulateAndFinishAtEveryFrameRate() {
        for frameRate in [30.0, 60, 120] {
            var configuration = enabledMouse(speed: 10, minimumStep: 100)
            configuration.durationLevel = 5
            var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
            _ = processor.receive(wheel(x: -1, y: 1), at: 0)
            _ = processor.receive(wheel(x: -1, y: 1), at: 0.01)
            var total = MouseScrollVector.zero
            for frame in 1...Int(frameRate) {
                let output = processor.sample(at: Double(frame) / frameRate)
                #expect(output.x <= 0 && output.y >= 0)
                total.x += output.x
                total.y += output.y
            }
            #expect(total == MouseScrollVector(x: -2000, y: 2000))
            #expect(!processor.hasPending)
        }
    }

    @Test func immediateModeIgnoresMinimumStepAndStepChangeCancelsAnimation() {
        var configuration = enabledMouse(speed: 2, minimumStep: 20)
        var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
        _ = processor.receive(wheel(y: 8), at: 0)
        #expect(processor.sample(at: 1).y == 40)
        _ = processor.receive(wheel(y: 8), at: 2)
        configuration.minimumStep = 100
        processor.configure(configuration)
        #expect(!processor.hasPending && processor.sample(at: 3).isZero)
        configuration.smooth = false
        processor.configure(configuration)
        #expect(processor.receive(wheel(y: 8), at: 4) == .immediate)
        #expect(processor.configuration.multiplier == 2)
        #expect(!processor.hasPending)
    }

    @Test func smoothingIsIdenticalForBrowsersAndUnlistedApplications() {
        var reference: [MouseScrollVector]?
        for bundle in ["com.google.Chrome", "com.apple.Safari", "test.unlisted.player", "test.reader"] {
            var processor = MouseScrollProcessor(configuration: enabledMouse(), ownPID: 42)
            var input = wheel(y: 8)
            input.targetBundleID = bundle
            #expect(processor.receive(input, at: 0) == .smooth)
            let output = (1...48).map { processor.sample(at: Double($0) / 120) }
            if let reference { #expect(output == reference) } else { reference = output }
            #expect(output.filter { !$0.isZero }.count > 1)
            #expect(output.reduce(0) { $0 + $1.y } == 8)
        }
    }

    @Test func adaptiveResponsePreservesDistanceAcrossDurationAndSpeedSettings() {
        for duration in [0.1, 0.18, 0.5] {
            for speed in [0.5, 1, 2.2, 3, 10] {
                for distance in [2.0, 8, 40, 80, -2, -8, -40, -80] {
                    var configuration = enabledMouse(speed: speed)
                    configuration.duration = duration
                    var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
                    #expect(processor.receive(wheel(y: distance), at: 0) == .smooth)
                    var total = 0.0
                    for frame in 1...60 {
                        let delta = processor.sample(at: Double(frame) / 120).y
                        #expect(delta == 0 || delta.sign == distance.sign)
                        total += delta
                    }
                    #expect(abs(total - distance * speed) < 1)
                    #expect(!processor.hasPending)
                }
            }
        }
    }

    @Test func durationLevelChangesAnimationProgressWithoutChangingDistance() {
        var earlyDistances: [Double] = []
        for level in [1.0, 1.8, 5.0] {
            var configuration = enabledMouse()
            configuration.durationLevel = level
            var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
            #expect(processor.receive(wheel(y: 200), at: 0) == .smooth)
            let early = processor.sample(at: 0.05).y
            earlyDistances.append(early)
            var total = early + processor.sample(at: 0.11).y
            #expect(processor.hasPending == (level > 1))
            total += processor.sample(at: 0.19).y
            #expect(processor.hasPending == (level > 1.8))
            total += processor.sample(at: 0.51).y
            #expect(!processor.hasPending)
            #expect(total == 200)
        }
        // 同一时间点，较短时长应已滚过更长距离，不能只验证最终位移。
        #expect(earlyDistances[0] > earlyDistances[1])
        #expect(earlyDistances[1] > earlyDistances[2])
    }

    @Test func ordinaryPageSmallWheelsAlwaysUseSmoothPixels() {
        for speed in [0.5, 1, 2.2, 3] {
            var processor = MouseScrollProcessor(configuration: enabledMouse(speed: speed), ownPID: 42)
            for (index, delta) in [8.0, 12, 8, 40, 8].enumerated() {
                let time = Double(index)
                #expect(processor.receive(wheel(y: delta), at: time) == .smooth)
                #expect(processor.hasPending)
                var sum = 0.0
                var frames = 0
                for frame in 1...24 {
                    let output = processor.sample(at: time + Double(frame) / 120).y
                    sum += output
                    if output != 0 { frames += 1 }
                }
                #expect(abs(sum - delta * speed) < 1)
                #expect(frames > 1)
                #expect(!processor.hasPending)
            }
        }
    }

    @Test func shortScrollRespondsEarlyWithoutChangingEventModeOrDistance() {
        for speed in [1.0, 2.2, 3] {
            for reversed in [false, true] {
                var configuration = enabledMouse(reversed: reversed, speed: speed)
                configuration.remoteCompatibility = true
                var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
                var input = wheel(y: 8)
                input.continuous = true
                #expect(processor.receive(input, at: 0) == .smooth)
                let first = processor.sample(at: 1 / 120.0).y
                #expect(abs(first) >= 3)
                #expect(abs(first) < 8 * speed)
                var total = first
                for frame in 2...48 { total += processor.sample(at: Double(frame) / 120).y }
                #expect(abs(total - 8 * configuration.multiplier) < 1)
                #expect(!processor.hasPending)
            }
        }
    }

    @Test func smallWheelsRemainSmoothBeforeDuringAndAfterLargeAnimation() {
        var processor = MouseScrollProcessor(configuration: enabledMouse(), ownPID: 42)
        #expect(processor.receive(wheel(y: 40), at: 0) == .smooth)
        #expect(processor.receive(wheel(y: 5), at: 0.01) == .smooth)
        #expect(processor.sample(at: 1).y == 45)
        #expect(processor.receive(wheel(y: 5), at: 2) == .smooth)
        #expect(processor.sample(at: 3).y == 5)
        #expect(processor.receive(wheel(y: 40), at: 4) == .smooth)
        var otherWindow = wheel(y: 5)
        otherWindow.targetWindow += 1
        #expect(processor.receive(otherWindow, at: 4.01) == .smooth)
        #expect(processor.sample(at: 5).y == 5)
    }

    @Test func permissionGateReusesResultsWithinBoundedActiveInterval() {
        var gate = MouseScrollPermissionGate()
        var checks = 0
        for frame in 0..<120 {
            let allowed = gate.allows(at: Double(frame) / 120) { checks += 1; return true }
            #expect(allowed)
        }
        #expect(checks >= 9 && checks <= 11)
    }

    @Test func permissionGateRechecksRevocationForcedRecoveryAndClockChanges() {
        var gate = MouseScrollPermissionGate()
        var allowed = true
        var checks = 0
        func check() -> Bool { checks += 1; return allowed }
        let initial = gate.allows(at: 1, check: check)
        #expect(initial)
        allowed = false
        let cached = gate.allows(at: 1.09, check: check)
        let revoked = gate.allows(at: 1.101, check: check)
        #expect(cached)
        #expect(!revoked)
        #expect(checks == 2)
        allowed = true
        let restored = gate.allows(at: 1.11, force: true, check: check)
        #expect(restored)
        allowed = false
        let reversedClock = gate.allows(at: 0.5, check: check)
        let invalidClock = gate.allows(at: .nan, check: check)
        #expect(!reversedClock)
        #expect(!invalidClock)
        #expect(checks == 4)
    }

    @Test func smoothDistanceAndSpeedAreIndependentOfFrameRate() {
        for frames in [12, 30, 60, 120] {
            var processor = MouseScrollProcessor(configuration: enabledMouse(speed: 1.5), ownPID: 42)
            #expect(processor.receive(wheel(x: -20, y: 40), at: 10) == .smooth)
            var sum = MouseScrollVector.zero
            for frame in 1...frames {
                let delta = processor.sample(at: 10 + Double(frame) / Double(frames))
                #expect(delta.x <= 0 && delta.y >= 0)
                sum.x += delta.x
                sum.y += delta.y
            }
            #expect(abs(sum.x + 30) < 1 && abs(sum.y - 60) < 1)
            #expect(!processor.hasPending)
            #expect(processor.sample(at: 20).isZero)
        }
    }

    @Test func fractionalPixelsSurviveManyCompletedGestures() {
        var processor = MouseScrollProcessor(configuration: enabledMouse(speed: 0.5), ownPID: 42)
        var total = 0.0
        for index in 0..<100 {
            let time = Double(index)
            #expect(processor.receive(wheel(y: 1), at: time) == .smooth)
            total += processor.sample(at: time + 0.5).y
            #expect(!processor.hasPending)
        }
        #expect(total == 50)
    }

    @Test func repeatedInputAccumulatesAndDirectionChangeDropsOldRemainderPerAxis() {
        var processor = MouseScrollProcessor(configuration: enabledMouse(), ownPID: 42)
        _ = processor.receive(wheel(x: 10, y: 100), at: 0)
        _ = processor.receive(wheel(x: 10, y: 100), at: 0.01)
        #expect(processor.sample(at: 0.5) == MouseScrollVector(x: 20, y: 200))
        _ = processor.receive(wheel(x: 20, y: 100), at: 1)
        _ = processor.sample(at: 1.03)
        _ = processor.receive(wheel(x: 0, y: -5), at: 1.04)
        let delta = processor.sample(at: 2)
        #expect(delta.y == -5)
        #expect(delta.x > 0)
        #expect(!processor.hasPending)
    }

    @Test func reversingAffectsBothAxesAndImmediateModeRetainsMultiplier() {
        var processor = MouseScrollProcessor(configuration: enabledMouse(reversed: true, speed: 2), ownPID: 42)
        _ = processor.receive(wheel(x: -10, y: 20), at: 0)
        #expect(processor.sample(at: 1) == MouseScrollVector(x: 20, y: -40))
        processor.configure(enabledMouse(smooth: false, reversed: true, speed: 0.5))
        #expect(processor.receive(wheel(), at: 2) == .immediate)
        #expect(processor.configuration.multiplier == -0.5)
        #expect(!processor.hasPending)
    }

    @Test func nativeUnknownExcludedAndOwnEventsPassAndCancelPendingWork() {
        var configuration = enabledMouse()
        configuration.excludedApps = ["test.excluded"]
        let variants: [(inout MouseScrollInput) -> Void] = [
            { $0.continuous = true }, { $0.hasPhase = true }, { $0.hasOtherAxis = true },
            { $0.commandOrControl = true }, { $0.targetPID = 0 }, { $0.targetPID = 42 },
            { $0.targetBundleID = nil }, { $0.targetBundleID = "test.excluded" },
            { $0.delta.y = .nan }, { $0.delta.y = .infinity }, { $0.delta = .zero },
        ]
        for change in variants {
            var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
            _ = processor.receive(wheel(), at: 0)
            var input = wheel()
            change(&input)
            #expect(processor.receive(input, at: 0.01) == .passThrough)
            #expect(!processor.hasPending)
            #expect(processor.sample(at: 1).isZero)
        }
        var disabled = MouseScrollProcessor(configuration: .init(), ownPID: 42)
        #expect(disabled.receive(wheel(), at: 0) == .passThrough)
    }

    @Test func remoteCompatibilityHandlesUnphasedContinuousWheelsButPreservesGesturesAndExclusions() throws {
        // 远程桌面可能将实体鼠标滚轮转换为无手势阶段的连续像素事件。
        let data = Data("""
            {"enabled":true,"smooth":true,"reversed":true,"speed":2.2,"duration":0.18,
             "excludedApps":["test.excluded"],"remoteCompatibility":true}
            """.utf8)
        let configuration = try JSONDecoder().decode(MouseScrollConfiguration.self, from: data)
        #expect(configuration.remoteCompatibility)
        var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
        var remote = wheel(x: -10, y: 20)
        remote.continuous = true
        #expect(processor.receive(remote, at: 0) == .smooth)
        let delta = processor.sample(at: 1)
        #expect(abs(delta.x - 33.6 * 2.2) < 1 && abs(delta.y + 33.6 * 2.2) < 1)
        remote.hasPhase = true
        #expect(processor.receive(remote, at: 2) == .passThrough)
        remote.hasPhase = false
        remote.targetBundleID = "test.excluded"
        #expect(processor.receive(remote, at: 3) == .passThrough)
        remote.targetBundleID = "test.scroll"
        remote.commandOrControl = true
        #expect(processor.receive(remote, at: 4) == .passThrough)
        remote.commandOrControl = false
        remote.targetPID = 42
        #expect(processor.receive(remote, at: 5) == .passThrough)
        #expect(!processor.hasPending)
        remote.targetPID = 12345
        var immediateConfiguration = configuration
        immediateConfiguration.smooth = false
        processor.configure(immediateConfiguration)
        #expect(processor.receive(remote, at: 6) == .immediate)
        #expect(processor.configuration.multiplier == -2.2)
    }

    @Test func olderMousePreferencesKeepUserChoicesWhenRemoteOptionIsMissing() throws {
        let data = Data("""
            {"enabled":true,"smooth":false,"reversed":true,"speed":2.2,"duration":0.27,
             "excludedApps":["test.excluded"]}
            """.utf8)
        let configuration = try JSONDecoder().decode(MouseScrollConfiguration.self, from: data)
        #expect(configuration.enabled && !configuration.smooth && configuration.reversed)
        #expect(configuration.speed == 2.2 && configuration.duration == 0.27)
        #expect(configuration.minimumStep == 33.6)
        #expect(configuration.excludedApps == ["test.excluded"])
        #expect(!configuration.remoteCompatibility)
        var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
        var remote = wheel()
        remote.continuous = true
        #expect(processor.receive(remote, at: 0) == .passThrough)
    }

    @Test func generatedEventsDoNotCancelAndNewTargetWindowOrFlagsDiscardOldMotion() {
        for contextChange in 0..<3 {
            var processor = MouseScrollProcessor(configuration: enabledMouse(), ownPID: 42)
            _ = processor.receive(wheel(y: 100), at: 0)
            var generated = wheel()
            generated.generated = true
            #expect(processor.receive(generated, at: 0.01) == .passThrough)
            #expect(processor.hasPending)
            var next = wheel(y: 30)
            switch contextChange {
            case 0: next.targetPID += 1
            case 1: next.targetWindow += 1
            default: next.flags = 1
            }
            _ = processor.receive(next, at: 0.02)
            #expect(processor.sample(at: 1).y == 30)
            _ = processor.receive(wheel(), at: 2)
            processor.configure(enabledMouse(speed: 2))
            #expect(!processor.hasPending && processor.context == nil)
        }
    }

    @Test func normalizationAndIntegerScalingHandleBoundsAndReversals() {
        var configuration = enabledMouse()
        configuration.speed = .nan
        configuration.duration = .infinity
        configuration.minimumStep = -.infinity
        #expect(configuration.normalized.speed == 1 && configuration.normalized.duration == 0.18)
        #expect(configuration.normalized.minimumStep == 33.6)
        configuration.speed = 20
        configuration.duration = -1
        configuration.minimumStep = -1
        #expect(configuration.normalized.speed == 10 && configuration.normalized.duration == 0.1)
        #expect(configuration.normalized.minimumStep == 0.01)
        configuration.speed = -1
        configuration.duration = 20
        configuration.minimumStep = 200
        #expect(configuration.normalized.speed == 0.5 && configuration.normalized.duration == 0.5)
        #expect(configuration.normalized.minimumStep == 100)
        for boundary in [0.01, 100] {
            configuration.minimumStep = boundary
            #expect(configuration.normalized.minimumStep == boundary)
        }
        for boundary in [0.5, 10] {
            configuration.speed = boundary
            #expect(configuration.normalized.speed == boundary)
        }
        for level in [1.0, 1.8, 2.61, 5] {
            configuration.durationLevel = level
            #expect(abs(configuration.normalized.durationLevel - level) < 0.000_001)
        }
        var quantizer = MouseScrollQuantizer()
        #expect(quantizer.scale(1, by: 0.5) == 0)
        #expect(quantizer.scale(1, by: 0.5) == 1)
        #expect(quantizer.scale(1, by: 0.5) == 0)
        #expect(quantizer.scale(-2, by: 0.5) == -1)
        #expect(quantizer.scale(Int64.max, by: 3) == Int64(Int32.max))
    }
}

@Suite("鼠标系统事件转换") struct MouseScrollEventTests {
    private func event() throws -> CGEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                        wheelCount: 2, wheel1: 1, wheel2: -2, wheel3: 0))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 12345)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 91)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 10)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -20)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -2)
        event.flags = .maskShift
        event.location = CGPoint(x: 200, y: 300)
        return event
    }

    @Test func decodingPreservesActualRecipientAndDetectsNativeInput() throws {
        let event = try event()
        let apps: [Int32: String] = [12345: "test.scroll"]
        let input = MouseScrollEventAdapter.input(event, applications: apps)
        #expect(input.delta == MouseScrollVector(x: -20, y: 10))
        #expect(input.targetPID == 12345 && input.targetBundleID == "test.scroll")
        #expect(input.targetWindow == event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        #expect(!input.continuous && !input.commandOrControl)
        #expect(MouseScrollEventAdapter.input(event, applications: [:]).targetBundleID == nil)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        event.flags = [.maskControl, .maskCommand]
        let native = MouseScrollEventAdapter.input(event, applications: apps)
        #expect(native.continuous && native.hasPhase && native.commandOrControl)
        event.setIntegerValueField(.eventSourceUserData, value: MouseScrollEventAdapter.marker)
        #expect(MouseScrollEventAdapter.input(event, applications: apps).generated)
    }

    @Test func immediateScalingUpdatesAllRepresentationsWithoutChangingMetadata() throws {
        let event = try event()
        let input = MouseScrollEventAdapter.input(event, applications: [12345: "test.scroll"])
        var adapter = MouseScrollEventAdapter()
        adapter.scale(event, input: input, multiplier: -1.5)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 3)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -15)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 30)
        #expect(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -1.5)
        #expect(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == 3)
        #expect(event.flags == .maskShift && event.location == CGPoint(x: 200, y: 300))
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
        #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == 12345)
    }

    @Test func generatedPixelEventsKeepLocationModifiersAndRecipient() throws {
        let template = try event()
        let output = try #require(MouseScrollEventAdapter.output(MouseScrollVector(x: -3, y: 7), template: template))
        #expect(output.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 7)
        #expect(output.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -3)
        #expect(output.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(output.getIntegerValueField(.scrollWheelEventScrollPhase) == 0)
        #expect(output.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0)
        #expect(output.flags == template.flags && output.location == template.location)
        #expect(output.getIntegerValueField(.eventTargetUnixProcessID) == 12345)
        #expect(output.getIntegerValueField(.mouseEventWindowUnderMousePointer)
                == template.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        #expect(output.getIntegerValueField(.eventSourceUserData) == MouseScrollEventAdapter.marker)
    }

    @Test func immediateWheelsKeepNativeUnitsAndMetadataWhileApplyingSpeedAndDirection() throws {
        for precise in [false, true] {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                            wheelCount: 2, wheel1: precise ? 8 : 1, wheel2: 0, wheel3: 0))
            event.setIntegerValueField(.eventTargetUnixProcessID, value: 12345)
            event.flags = .maskShift
            event.location = CGPoint(x: 200, y: 300)
            let input = MouseScrollEventAdapter.input(event, applications: [12345: "test.scroll"])
            var configuration = enabledMouse(smooth: false, reversed: true, speed: 2.2)
            configuration.remoteCompatibility = true
            var processor = MouseScrollProcessor(configuration: configuration, ownPID: 42)
            #expect(processor.receive(input, at: 0) == .immediate)
            var adapter = MouseScrollEventAdapter()
            adapter.scale(event, input: input, multiplier: processor.configuration.multiplier)
            #expect(abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                        - (precise ? 0.8 : 1) * -2.2) < 0.001)
            #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == (precise ? -17 : -22))
            #expect(event.getIntegerValueField(.eventSourceUserData) != MouseScrollEventAdapter.marker)
            #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == 12345)
            #expect(event.flags == .maskShift && event.location == CGPoint(x: 200, y: 300))
            #expect(!processor.hasPending)
            // 系统转换可能将带上档键的离散纵向滚动改写为横向，原始字段须先核对。
            let received = try #require(NSEvent(cgEvent: event))
            #expect(received.hasPreciseScrollingDeltas == precise)
        }
    }
}

@MainActor private final class MockMouseScrollDriver: MouseScrollDriving {
    var starts = 0
    var updates = 0
    var stops = 0
    var cancels = 0
    var callbacks: [@MainActor @Sendable (MouseScrollDriverStatus) -> Void] = []
    var latest: MouseScrollConfiguration?
    func start(configuration: MouseScrollConfiguration, applications: [Int32: String],
               status: @escaping @MainActor @Sendable (MouseScrollDriverStatus) -> Void) {
        starts += 1
        latest = configuration
        callbacks.append(status)
    }
    func update(configuration: MouseScrollConfiguration, applications: [Int32: String]) {
        updates += 1
        latest = configuration
    }
    func cancelAnimation() { cancels += 1 }
    func stop() { stops += 1 }
}

@Suite("鼠标设置与服务", .serialized) @MainActor struct MouseScrollServiceTests {
    @Test func invalidRuntimeParametersMatchPersistedAndDeliveredValuesWithoutDuplicateUpdates() throws {
        let suite = "MouseScrollNormalization." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let driver = MockMouseScrollDriver()
        let service = MouseScrollService(driver: driver, hasPermission: { true }, observesWorkspace: false)
        service.start()
        var delivered: [MouseScrollConfiguration] = []
        settings.onMouseChanged = {
            delivered.append(settings.mouse)
            service.apply(settings.mouse)
        }
        defer { settings.onMouseChanged = nil; service.stop() }
        settings.mouse.enabled = true
        settings.mouse.speed = 20
        #expect(settings.mouse.speed == 10)
        #expect(delivered.last?.speed == 10)
        #expect(driver.latest?.speed == 10)
        #expect(driver.latest == settings.mouse)
        #expect(AppSettings(defaults: defaults).mouse == settings.mouse)
        let count = delivered.count
        let updates = driver.updates
        settings.mouse.speed = 100
        #expect(delivered.count == count)
        #expect(driver.updates == updates)
        settings.mouse.minimumStep = -.infinity
        settings.mouse.duration = .nan
        #expect(settings.mouse.minimumStep == 33.6 && settings.mouse.duration == 0.18)
        #expect(AppSettings(defaults: defaults).mouse == settings.mouse)
        #expect(driver.latest == settings.mouse)
    }

    @Test func defaultIsOffAndSettingsPersistSeparatelyFromClipboardExclusions() throws {
        let suite = "MouseScrollSettings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.mouse.enabled && settings.mouse.smooth && !settings.mouse.reversed)
        #expect(settings.mouse.speed == 1 && settings.mouse.duration == 0.18)
        #expect(settings.mouse.minimumStep == 33.6)
        #expect(!settings.mouse.remoteCompatibility)
        settings.excludedApps = ["test.clipboard"]
        var changes = 0
        settings.onMouseChanged = { changes += 1 }
        settings.mouse = enabledMouse(reversed: true, speed: 2)
        settings.mouse.excludedApps = ["test.scroll"]
        settings.mouse.remoteCompatibility = true
        settings.mouse.minimumStep = 42.01
        settings.mouse.speed = 10
        settings.mouse.durationLevel = 5
        #expect(changes == 6)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.mouse == settings.mouse)
        #expect(restored.excludedApps == ["test.clipboard"])
        restored.mouse = .init()
        #expect(AppSettings(defaults: defaults).mouse == MouseScrollConfiguration())
        #expect(restored.excludedApps == ["test.clipboard"])
        defaults.set(Data("invalid".utf8), forKey: "mouseScrollConfiguration")
        #expect(AppSettings(defaults: defaults).mouse == .init())
    }

    @Test func legacyPreferencesClampDurationWithoutChangingItsStoredUnit() throws {
        let suite = "MouseScrollLegacySettings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for oldDuration in [0.08, 0.18, 0.27, 0.4] {
            defaults.set(Data("""
                {"enabled":true,"smooth":true,"reversed":true,"speed":2.2,"duration":\(oldDuration),
                 "excludedApps":["test.excluded"],"remoteCompatibility":true}
                """.utf8), forKey: "mouseScrollConfiguration")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.mouse.minimumStep == 33.6)
            #expect(settings.mouse.speed == 2.2)
            #expect(settings.mouse.duration == max(0.1, oldDuration))
            #expect(settings.mouse.enabled && settings.mouse.reversed && settings.mouse.remoteCompatibility)
            #expect(settings.mouse.excludedApps == ["test.excluded"])
            settings.mouse.minimumStep = 0.01
            let data = try #require(defaults.data(forKey: "mouseScrollConfiguration"))
            let stored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(stored["duration"] as? Double == max(0.1, oldDuration))
            #expect(stored["minimumStep"] as? Double == 0.01)
            #expect(AppSettings(defaults: defaults).mouse == settings.mouse)
        }
    }

    @Test func startIsOptInAndOnlyReportsRunningAfterDriverAcknowledges() {
        let driver = MockMouseScrollDriver()
        let service = MouseScrollService(driver: driver, hasPermission: { true }, observesWorkspace: false)
        service.start()
        #expect(driver.starts == 0 && service.status == .disabled)
        service.apply(enabledMouse())
        #expect(driver.starts == 1 && service.status == .starting)
        driver.callbacks[0](.running)
        #expect(service.status == .running)
        service.start()
        service.refresh()
        #expect(driver.starts == 1)
        service.apply(enabledMouse(speed: 2))
        #expect(driver.updates == 1 && driver.latest?.speed == 2)
        service.apply(.init())
        #expect(driver.stops == 1 && service.status == .disabled)
        driver.callbacks[0](.running)
        #expect(service.status == .disabled)
        service.stop()
        service.stop()
        #expect(driver.stops == 1)
    }

    @Test func permissionFailureRetryAndStaleCallbacksDoNotProduceFalseRunningState() {
        var allowed = false
        let driver = MockMouseScrollDriver()
        let service = MouseScrollService(configuration: enabledMouse(), driver: driver,
                                        hasPermission: { allowed }, observesWorkspace: false)
        service.start()
        #expect(service.status == .permissionRequired && driver.starts == 0)
        allowed = true
        service.refresh()
        #expect(driver.starts == 1 && service.status == .starting)
        driver.callbacks[0](.failed)
        #expect(service.status == .failed && driver.stops == 1)
        service.refresh()
        #expect(driver.starts == 2)
        driver.callbacks[0](.running)
        #expect(service.status == .starting)
        driver.callbacks[1](.running)
        #expect(service.status == .running)
        allowed = false
        service.refresh()
        #expect(service.status == .permissionRequired && driver.stops == 2)
        service.stop()
    }

    @Test func overlappingSessionReasonsStopAndResumeExactlyOnceAndKeepNewConfiguration() {
        let driver = MockMouseScrollDriver()
        let service = MouseScrollService(configuration: enabledMouse(), driver: driver,
                                        hasPermission: { true }, observesWorkspace: false)
        service.start()
        driver.callbacks[0](.running)
        service.setSessionActive(false, reason: "sleep")
        service.setSessionActive(false, reason: "lock")
        #expect(driver.stops == 1 && service.status == .paused)
        service.apply(enabledMouse(reversed: true))
        #expect(driver.starts == 1)
        service.setSessionActive(true, reason: "sleep")
        #expect(service.status == .paused && driver.starts == 1)
        service.setSessionActive(true, reason: "lock")
        #expect(driver.starts == 2 && driver.latest?.reversed == true)
        driver.callbacks[1](.running)
        service.stop()
        #expect(driver.stops == 2 && service.status == .disabled)
        service.start()
        #expect(driver.starts == 3)
        service.stop()
    }
}

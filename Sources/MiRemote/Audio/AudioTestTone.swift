import Foundation

enum VoiceInputRoutingMode: String, CaseIterable {
    case automatic
    case manual
}

enum TestToneResult: Equatable {
    case completed
    case busy
    case outputDeviceMissing
    case routingFailed
    case engineFailed(String)
    case preempted
}

enum AudioActivity: Equatable {
    case idle, testTone, remoteVoice
}

private final class TestToneResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TestToneResult?

    func set(_ result: TestToneResult) { lock.withLock { value = result } }
    func get() -> TestToneResult? { lock.withLock { value } }
}

private final class TestToneCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    func get() -> Int { lock.withLock { value } }
}

private final class TestToneAudioStub: AudioStreaming {
    let startResult: Result<Void, Error>
    private(set) var writtenSamples = 0
    private(set) var immediateStops = 0

    init(startResult: Result<Void, Error>) { self.startResult = startResult }
    func startStream(sampleRate: Double) -> Result<Void, Error> { startResult }
    func write(_ samples: [Int16]) { writtenSamples += samples.count }
    func streamStopped() {}
    func stopImmediately() { immediateStops += 1 }
}

/// 测试音与真实语音的互斥门。真实语音可抢占测试音，测试音不能抢占真实语音。
final class AudioActivityCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AudioActivity = .idle
    private var cancelTest: (() -> Void)?
    private let inputQueue = DispatchQueue(label: "com.miremote.input-restore")
    private var inputGeneration = 0
    private var pendingInputRestore: (() -> Void)?

    func beginTest(cancel: @escaping () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .idle else { return false }
        // 先结束旧语音的恢复责任，测试音再接管输入，旧定时器不得跨会话执行。
        restoreInputNow()
        state = .testTone
        cancelTest = cancel
        return true
    }

    func beginRemoteVoice() {
        let cancel: (() -> Void)? = {
            lock.lock(); defer { lock.unlock() }
            let c = state == .testTone ? cancelTest : nil
            state = .remoteVoice
            cancelTest = nil
            return c
        }()
        cancel?()
        inputQueue.sync { inputGeneration += 1 } // 暂停旧恢复，但保留恢复责任供零帧会话继承。
    }

    func scheduleInputRestore(_ restore: (() -> Void)?, delay: TimeInterval = 1.2) {
        inputQueue.sync {
            if let restore { pendingInputRestore = restore }
            inputGeneration += 1
            let generation = inputGeneration
            guard pendingInputRestore != nil else { return }
            inputQueue.asyncAfter(deadline: .now() + delay) { [self] in
                guard generation == inputGeneration else { return }
                let work = pendingInputRestore
                pendingInputRestore = nil
                work?()
            }
        }
    }

    func restoreInputNow(_ restore: (() -> Void)? = nil) {
        inputQueue.sync {
            inputGeneration += 1
            let work = restore ?? pendingInputRestore
            pendingInputRestore = nil
            work?()
        }
    }

    func endTest() {
        lock.lock(); defer { lock.unlock() }
        if state == .testTone { state = .idle }
        cancelTest = nil
    }

    func endRemoteVoice() {
        lock.lock(); defer { lock.unlock() }
        if state == .remoteVoice { state = .idle }
    }

    var current: AudioActivity {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    static func selfCheck() -> Bool {
        let gate = AudioActivityCoordinator()
        var cancelled = 0
        guard gate.beginTest(cancel: { cancelled += 1 }), gate.current == .testTone else { return false }
        guard !gate.beginTest(cancel: {}), cancelled == 0 else { return false }
        gate.beginRemoteVoice()
        guard gate.current == .remoteVoice, cancelled == 1,
              !gate.beginTest(cancel: {}) else { return false }
        gate.endRemoteVoice()
        return gate.current == .idle
    }
}

enum TestToneGenerator {
    static let sampleRate = 16_000.0
    static let duration = 1.0
    static let frequency = 1_000.0
    static let peakDBFS = -18.0
    static let fadeSeconds = 0.02

    static func samples() -> [Int16] {
        let count = Int(sampleRate * duration)
        let peak = pow(10.0, peakDBFS / 20.0)
        let fadeCount = max(1, Int(sampleRate * fadeSeconds))
        return (0..<count).map { i in
            let fadeIn = min(1.0, Double(i) / Double(fadeCount))
            let fadeOut = min(1.0, Double(count - 1 - i) / Double(fadeCount))
            let envelope = max(0, min(fadeIn, fadeOut))
            let value = sin(2.0 * .pi * frequency * Double(i) / sampleRate) * peak * envelope
            return Int16(max(-32767, min(32767, Int((value * 32767.0).rounded()))))
        }
    }

    static func selfCheck() -> Bool {
        let tone = samples()
        guard tone.count == 16_000, tone.first == 0, tone.last == 0 else { return false }
        let peak = Double(tone.map { abs(Int($0)) }.max() ?? 0) / 32767.0
        let db = 20 * log10(max(peak, 0.000_001))
        guard (-19.0 ... -17.0).contains(db) else { return false }
        // 1 秒内 1kHz 正弦约有 2000 次过零；淡入首样本为零，给少量边界容差。
        var crossings = 0
        for i in 1..<tone.count where (tone[i - 1] < 0 && tone[i] >= 0) || (tone[i - 1] > 0 && tone[i] <= 0) {
            crossings += 1
        }
        let earlyPeak = tone.prefix(8).map { abs(Int($0)) }.max() ?? 0
        let steadyPeak = tone[400..<408].map { abs(Int($0)) }.max() ?? 1
        let tailPeak = tone.suffix(8).map { abs(Int($0)) }.max() ?? 0
        return (1_990...2_010).contains(crossings)
            && earlyPeak < steadyPeak / 10 && tailPeak < steadyPeak / 10
    }
}

final class AudioTestToneService: @unchecked Sendable {
    private let outputName: String?
    private let micDeviceName: String
    private let activity: AudioActivityCoordinator
    private weak var statistics: UsageStatisticsStore?
    private let outputAvailable: (String) -> Bool
    private let engageInput: (String) -> Bool
    private let restoreInput: () -> Void
    private let bridgeFactory: (String?) -> AudioStreaming
    private let callbackQueue: DispatchQueue
    private let completionDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.miremote.audio-test-tone")
    private var generation = 0
    private var activeBridge: AudioStreaming?
    private var switchedInput = false
    private var completion: ((TestToneResult) -> Void)?

    init(outputName: String?, micDeviceName: String,
         activity: AudioActivityCoordinator, statistics: UsageStatisticsStore?,
         outputAvailable: @escaping (String) -> Bool = { AudioBridge.hasOutputDevice(named: $0) },
         engageInput: @escaping (String) -> Bool = { DefaultInput.engage(deviceName: $0) },
         restoreInput: @escaping () -> Void = { DefaultInput.restore() },
         bridgeFactory: @escaping (String?) -> AudioStreaming = { AudioBridge(deviceName: $0) },
         callbackQueue: DispatchQueue = .main,
         completionDelay: TimeInterval = 1.25) {
        self.outputName = outputName
        self.micDeviceName = micDeviceName
        self.activity = activity
        self.statistics = statistics
        self.outputAvailable = outputAvailable
        self.engageInput = engageInput
        self.restoreInput = restoreInput
        self.bridgeFactory = bridgeFactory
        self.callbackQueue = callbackQueue
        self.completionDelay = completionDelay
    }

    func play(routing: VoiceInputRoutingMode, completion: @escaping (TestToneResult) -> Void) {
        queue.async { [weak self] in self?.start(routing: routing, completion: completion) }
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(result: .preempted) }
    }

    func cancelAndWait() {
        queue.sync { finish(result: .preempted) }
    }

    private func start(routing: VoiceInputRoutingMode, completion: @escaping (TestToneResult) -> Void) {
        guard activity.beginTest(cancel: { [weak self] in self?.cancelAndWait() }) else {
            deliver(.busy, to: completion)
            return
        }
        generation &+= 1
        let token = generation
        self.completion = completion

        if let outputName, !outputAvailable(outputName) {
            finish(result: .outputDeviceMissing)
            return
        }
        if routing == .automatic {
            guard engageInput(micDeviceName) else {
                finish(result: .routingFailed)
                return
            }
            switchedInput = true
        }

        let bridge = bridgeFactory(outputName)
        activeBridge = bridge
        switch bridge.startStream(sampleRate: TestToneGenerator.sampleRate) {
        case .failure(let error):
            finish(result: .engineFailed(error.localizedDescription))
        case .success:
            bridge.write(TestToneGenerator.samples())
            bridge.streamStopped()
            statistics?.recordTestTone()
            queue.asyncAfter(deadline: .now() + completionDelay) { [weak self] in
                guard let self, token == self.generation else { return }
                self.finish(result: .completed)
            }
        }
    }

    private func finish(result: TestToneResult) {
        guard completion != nil || activeBridge != nil || switchedInput else {
            activity.endTest()
            return
        }
        generation &+= 1
        if result == .completed {
            activeBridge?.streamStopped()
        } else {
            activeBridge?.stopImmediately()
        }
        activeBridge = nil
        if switchedInput { restoreInput() }
        switchedInput = false
        activity.endTest()
        let callback = completion
        completion = nil
        if let callback { deliver(result, to: callback) }
    }

    private func deliver(_ result: TestToneResult, to callback: @escaping (TestToneResult) -> Void) {
        callbackQueue.async { callback(result) }
    }

    static func selfCheck() -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miremote-tone-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = UsageStatisticsStore(fileURL: dir.appendingPathComponent("usage-stats.json"))
        let callbackQueue = DispatchQueue(label: "com.miremote.audio-test-tone.self-check")

        func awaitResult(_ service: AudioTestToneService,
                         routing: VoiceInputRoutingMode) -> TestToneResult? {
            let result = TestToneResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            service.play(routing: routing) { value in
                result.set(value)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 2) == .success else { return nil }
            return result.get()
        }

        let busyActivity = AudioActivityCoordinator()
        busyActivity.beginRemoteVoice()
        let busy = AudioTestToneService(
            outputName: nil, micDeviceName: "BlackHole", activity: busyActivity,
            statistics: stats, callbackQueue: callbackQueue, completionDelay: 0)
        guard awaitResult(busy, routing: .manual) == .busy else { return false }

        let missing = AudioTestToneService(
            outputName: "Missing", micDeviceName: "BlackHole", activity: AudioActivityCoordinator(),
            statistics: stats, outputAvailable: { _ in false },
            callbackQueue: callbackQueue, completionDelay: 0)
        guard awaitResult(missing, routing: .manual) == .outputDeviceMissing else { return false }

        let routing = AudioTestToneService(
            outputName: "Output", micDeviceName: "BlackHole", activity: AudioActivityCoordinator(),
            statistics: stats, outputAvailable: { _ in true }, engageInput: { _ in false },
            callbackQueue: callbackQueue, completionDelay: 0)
        guard awaitResult(routing, routing: .automatic) == .routingFailed else { return false }

        let engineError = NSError(domain: "AudioTestToneSelfCheck", code: 1)
        let engine = AudioTestToneService(
            outputName: nil, micDeviceName: "BlackHole", activity: AudioActivityCoordinator(),
            statistics: stats, bridgeFactory: { _ in TestToneAudioStub(startResult: .failure(engineError)) },
            callbackQueue: callbackQueue, completionDelay: 0)
        guard case .engineFailed = awaitResult(engine, routing: .manual) else { return false }
        stats.flush()
        guard stats.snapshot().today.testToneCount == 0 else { return false }

        let restoreCount = TestToneCounter()
        let successBridge = TestToneAudioStub(startResult: .success(()))
        let success = AudioTestToneService(
            outputName: nil, micDeviceName: "BlackHole", activity: AudioActivityCoordinator(),
            statistics: stats, engageInput: { _ in true },
            restoreInput: { restoreCount.increment() }, bridgeFactory: { _ in successBridge },
            callbackQueue: callbackQueue, completionDelay: 0)
        guard awaitResult(success, routing: .automatic) == .completed else { return false }
        stats.flush()
        guard successBridge.writtenSamples == 16_000
            && restoreCount.get() == 1
            && successBridge.immediateStops == 0
            && stats.snapshot().today.testToneCount == 1 else { return false }

        let activity = AudioActivityCoordinator()
        let preemptedBridge = TestToneAudioStub(startResult: .success(()))
        let result = TestToneResultBox()
        let done = DispatchSemaphore(value: 0)
        let preempted = AudioTestToneService(
            outputName: nil, micDeviceName: "BlackHole", activity: activity,
            statistics: nil, bridgeFactory: { _ in preemptedBridge },
            callbackQueue: callbackQueue, completionDelay: 60)
        preempted.play(routing: .manual) { value in result.set(value); done.signal() }
        preempted.queue.sync {} // 等待一秒 PCM 已写入并进入排空，再抢占。
        activity.beginRemoteVoice()
        guard preemptedBridge.writtenSamples == 16_000,
              preemptedBridge.immediateStops == 1,
              activity.current == .remoteVoice,
              done.wait(timeout: .now() + 2) == .success,
              result.get() == .preempted else { return false }
        preempted.cancelAndWait()
        activity.endRemoteVoice()
        return preemptedBridge.immediateStops == 1
    }
}

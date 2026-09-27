import Foundation

enum SessionLifecycleSelfTest {
    final class FakeAudio: AudioStreaming {
        var onWrite: (() -> Void)?
        func startStream(sampleRate: Double) -> Result<Void, Error> { .success(()) }
        func write(_ samples: [Int16]) { onWrite?() }
        func streamStopped() {}
        func stopImmediately() {}
    }
    final class FakeMic: @unchecked Sendable {
        private let lock = NSLock()
        private var selected = "original"
        private var saved: String?
        private var restores = 0
        func engage(_ name: String) -> Bool {
            lock.withLock {
                if selected == name { return true }
                if saved == nil { saved = selected }
                selected = name
                return true
            }
        }
        func restore() {
            lock.withLock {
                restores += 1
                if let saved { selected = saved }
                saved = nil
            }
        }
        var state: String { lock.withLock { "input=\(selected), restores=\(restores)" } }
    }
    static func voice(_ mic: FakeMic, _ activity: AudioActivityCoordinator) -> VoiceBridgeApp {
        VoiceBridgeApp(outputName: nil, wavPath: nil, gainDB: 0, verbose: false,
                       switchInput: true, doubao: false, audioActivity: activity,
                       audio: FakeAudio(), engageInput: { mic.engage($0) },
                       restoreInput: { mic.restore() }, beginTrigger: { _ in fatalError("Unexpected trigger") })
    }
    static func run() -> Bool {
        var passed = true
        func check(_ condition: Bool, _ message: String) {
            if !condition { passed = false; print("FAIL  会话生命周期：\(message)") }
        }
        do {
            let mic = FakeMic()
            let app = voice(mic, AudioActivityCoordinator())
            app.atvvVoiceStarted()
            app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
            app.atvvVoiceStopped()
            for _ in 0..<2 {
                app.atvvVoiceStarted()
                app.atvvVoiceStopped()
            }
            Thread.sleep(forTimeInterval: 1.5)
            check(mic.state == "input=original, restores=1", "连续零帧会话仍恢复原输入且只恢复一次")
            app.forceEndSessionIfActive()
            check(mic.state == "input=original, restores=1", "延迟恢复完成后退出不重复恢复")
        }
        do {
            let mic = FakeMic()
            let activity = AudioActivityCoordinator()
            let app = voice(mic, activity)
            app.atvvVoiceStarted()
            app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
            app.atvvVoiceStopped()
            Thread.sleep(forTimeInterval: 0.5)
            let audio = FakeAudio()
            let written = DispatchSemaphore(value: 0)
            audio.onWrite = { written.signal() }
            let tone = AudioTestToneService(outputName: nil, micDeviceName: "BlackHole",
                activity: activity, statistics: nil, engageInput: { mic.engage($0) },
                restoreInput: { mic.restore() }, bridgeFactory: { _ in audio },
                callbackQueue: DispatchQueue(label: "selfcheck.lifecycle"))
            tone.play(routing: .automatic) { _ in }
            check(written.wait(timeout: .now() + 1) == .success, "语音后测试音可启动")
            Thread.sleep(forTimeInterval: 0.9)
            check(activity.current == .testTone && mic.state == "input=BlackHole, restores=1",
                  "旧语音定时器不恢复测试音持有的输入")
            tone.cancelAndWait()
            check(mic.state == "input=original, restores=2", "测试音结束还原原输入")
        }
        do {
            let mic = FakeMic()
            let app = voice(mic, AudioActivityCoordinator())
            app.atvvVoiceStarted()
            app.atvvVoiceStopped()
            app.forceEndSessionIfActive()
            check(mic.state == "input=original, restores=0", "独立零帧无路由副作用")
            app.atvvVoiceStarted()
            app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
            app.atvvVoiceStopped()
            app.atvvVoiceStarted()
            app.forceEndSessionIfActive()
            check(mic.state == "input=original, restores=1", "新零帧会话中退出仍履行旧恢复责任")
        }
        do {
            let mic = FakeMic()
            let activity = AudioActivityCoordinator()
            let app = voice(mic, activity)
            var voiceActive = false
            app.onVoiceActive = { voiceActive = $0 }
            app.atvvVoiceStarted()
            app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
            app.atvvDisconnected(error: "test out of range")
            check(!voiceActive && mic.state == "input=original, restores=1",
                  "收音中断连立即清除语音状态并恢复麦克风")
            app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
            check(mic.state == "input=original, restores=1", "断连后的迟到音频不重新接管麦克风")
            app.atvvConnected(deviceName: "test remote")
            app.atvvVoiceStarted()
            app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
            check(voiceActive && mic.state.contains("input=BlackHole"), "重连后可开始新语音会话")
            app.atvvDisconnected(error: nil)
            check(!voiceActive && mic.state == "input=original, restores=2", "再次断连仍正常清理")
        }
        checkMacros(check)
        return passed
    }

    private final class Runner: ActionRunning {
        var produced = 0
        func run(_ action: Action) {
            if case .macro(let steps) = action { MacroEngine.shared.run(steps, runner: self) }
            else { produced += 1 }
        }
    }

    private final class Primitives: MacroPrimitives {
        let token: MacroCancellation
        var actions = 0
        init(_ token: MacroCancellation) { self.token = token }
        func perform(_ action: Action) { actions += 1; token.cancel() }
        func typeText(_ text: String) { actions += 1 }
        func wait(ms: Int) {}
    }

    private static func checkMacros(_ check: (Bool, String) -> Void) {
        let runner = Runner()
        var config = MappingConfig()
        config.profiles = ["global": ["tv": KeyBinding(tap: .macro(steps: [
            .delay(ms: 60_000), .action(.system("mute"))]))]]
        let engine = MappingEngine(config: config, runner: runner, delegate: nil,
                                  dispatch: { $0() }, scheduleAfter: { _, _ in })
        func drain() -> Bool {
            let deadline = Date().addingTimeInterval(1)
            while MacroEngine.shared.isRunning && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return !MacroEngine.shared.isRunning
        }
        engine.handle(ButtonEvent(key: .tv, isDown: true, timeNs: 0))
        engine.handle(ButtonEvent(key: .tv, isDown: false, timeNs: 10_000_000))
        engine.setSuspended(true)
        check(drain() && runner.produced == 0, "暂停唤醒 60 秒延时并取消后续动作")
        engine.setSuspended(false)
        runner.run(.macro(steps: [.action(.system("mute"))]))
        check(drain() && runner.produced == 1, "恢复后可运行新宏")
        let token = MacroCancellation()
        let primitives = Primitives(token)
        MacroEngine.execute([.action(.macro(steps: [.action(.none), .action(.none)])), .action(.none)],
                            primitives: primitives, depth: 0, isCancelled: { token.isCancelled })
        check(primitives.actions == 1, "嵌套取消传播到内外层")
        let textToken = MacroCancellation()
        var chunks = 0
        MacroEngine.textChunks(String(repeating: "a", count: 100), cancellation: textToken) { _ in
            chunks += 1
            textToken.cancel()
        }
        check(chunks == 1, "文本分段取消后不发送后续段")
    }
}

import Foundation

/// 隔离音频输出、输入法和统计目录；不触发真实录音或快捷键。
enum ReliabilitySelfTest {
    private final class AudioStub: AudioStreaming {
        var startFails = false
        var starts = 0
        var samples = 0
        var immediateStops = 0
        func startStream(sampleRate: Double) -> Result<Void, Error> {
            starts += 1
            return startFails ? .failure(NSError(domain: "AudioSelfTest", code: 1)) : .success(())
        }
        func write(_ samples: [Int16]) { self.samples += samples.count }
        func streamStopped() {}
        func stopImmediately() { immediateStops += 1 }
    }

    static func run() -> Bool {
        var passed = true
        func check(_ condition: Bool, _ message: String) {
            if !condition { passed = false; print("FAIL  可靠性：\(message)") }
        }
        check(AudioBridge.failureAndCancellationSelfCheck(), "指定输出缺失不得回退，立即停止清空缓冲且幂等")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remokey-reliability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stats = UsageStatisticsStore(fileURL: dir.appendingPathComponent("voice.json"))
            for outputFails in [true, false] {
                let audio = AudioStub()
                audio.startFails = outputFails
                var engageCalls = 0
                var triggerCalls = 0
                var restoreCalls = 0
                var errors = 0
                let activity = AudioActivityCoordinator()
                let app = VoiceBridgeApp(
                    outputName: nil, wavPath: nil, gainDB: 0, verbose: false,
                    switchInput: true, doubao: true, audioActivity: activity,
                    usageStatistics: stats, audio: audio,
                    engageInput: { _ in engageCalls += 1; return false },
                    restoreInput: { restoreCalls += 1 },
                    beginTrigger: { _ in triggerCalls += 1 })
                app.onVoiceError = { _ in errors += 1 }
                app.atvvVoiceStarted()
                app.atvvAudioFrame(Data(), sync: nil)
                check(audio.starts == 0 && engageCalls == 0 && triggerCalls == 0,
                      "零帧会话不启动输出、不切输入、不触发输入法")
                app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
                app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
                check(audio.starts == 1 && audio.samples == 0 && triggerCalls == 0 && errors == 1,
                      "启动或路由失败后整段丢弃，仅提示一次")
                check(engageCalls == (outputFails ? 0 : 1) && restoreCalls == 1
                      && audio.immediateStops == 1, "输出失败不切麦克风，失败同步清理")
                check(activity.current == .remoteVoice, "失败会话保留互斥至 STOP")
                app.atvvVoiceStopped()
                check(activity.current == .idle, "失败 STOP 释放互斥")
                stats.flush()
                check(stats.snapshot().today.voiceSessions == 0, "失败不计入有效语音")

                // 下一次 START 恢复；手动路由不调用自动切换，也不触发真实输入法。
                audio.startFails = false
                app.switchInput = false
                app.doubao = false
                app.atvvVoiceStarted()
                app.atvvAudioFrame(Data([0x11, 0x22]), sync: nil)
                app.atvvVoiceStopped()
                check(audio.samples == 4 && errors == 1 && triggerCalls == 0,
                      "后续新会话可恢复，不残留失败锁存")
                stats.clear()
            }
            try checkStatistics(in: dir, check: check)
        } catch {
            check(false, "隔离统计测试失败：\(error)")
        }
        return SessionLifecycleSelfTest.run() && passed
    }

    private static func checkStatistics(in dir: URL, check: (Bool, String) -> Void) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 12))!
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }
        let url = dir.appendingPathComponent("history.json")
        let store = UsageStatisticsStore(fileURL: url, calendar: calendar, now: day(-200))
        for offset in [-200, -90, -89] { store.recordTestTone(at: day(offset)) }
        store.flush()
        // 稀疏使用、跨 DST，关闭记录后重启也应清理过期数据。
        let reloaded = UsageStatisticsStore(fileURL: url, enabled: false, calendar: calendar, now: now)
        func dates() throws -> [String: Any] {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            return object["days"] as! [String: Any]
        }
        check(try dates().count == 1, "自然日窗口保留第 89 天，删除第 90 天与第 200 天")
        _ = reloaded.snapshot(now: day(1))
        reloaded.flush()
        check(try dates().isEmpty, "常驻期间读取快照也清理刚过期日期")

        let clearURL = dir.appendingPathComponent("clear.json")
        let clearStore = UsageStatisticsStore(fileURL: clearURL, calendar: calendar, now: now)
        clearStore.recordTestTone(at: now)
        clearStore.flush()
        let before = try Data(contentsOf: clearURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        if case .success = clearStore.clear() { check(false, "不可写目录必须返回删除失败") }
        check(clearStore.snapshot(now: now).today.testToneCount == 1,
              "删除失败不清空内存")
        check(try Data(contentsOf: clearURL) == before, "删除失败保留磁盘原内容")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        if case .failure = clearStore.clear() { check(false, "权限恢复后允许重试") }
        check(clearStore.snapshot(now: now).today.testToneCount == 0
              && !FileManager.default.fileExists(atPath: clearURL.path), "清空成功删除内存与磁盘历史")
        if case .failure = clearStore.clear() { check(false, "重复清空不存在文件仍成功") }
    }
}

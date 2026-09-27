import Foundation

/// 仅在等待发现设备时重查系统连接。所有操作由 ATVV 串行队列调用。
final class ATVVDiscoveryRetry {
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private var token = 0
    private var work: DispatchWorkItem?

    init(queue: DispatchQueue, interval: TimeInterval = 3) {
        self.queue = queue
        self.interval = interval
    }

    func start(_ action: @escaping () -> Void) {
        guard work == nil else { return }
        schedule(token: token, action: action)
    }

    func stop() {
        token += 1
        work?.cancel()
        work = nil
    }

    private func schedule(token expected: Int, action: @escaping () -> Void) {
        let pending = DispatchWorkItem { [weak self] in
            guard let self, self.token == expected else { return }
            action()
            guard self.token == expected else { return }
            self.schedule(token: expected, action: action)
        }
        work = pending
        queue.asyncAfter(deadline: .now() + interval, execute: pending)
    }
}

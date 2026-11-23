import Foundation

/// App 侧：把扩展写的帧搬到 FrameBus。
/// Task 创建在 actor 隔离上下文里，会继承 actor 隔离，所以 last/bus 都不用再 await。
actor ExtensionFramePoller {
    private let bus: FrameBus
    private var task: Task<Void, Never>?
    private var last: AppGroupBridge.Snapshot?

    /// 45ms ≈ 22Hz 轮询，比扩展写帧快一倍，够跟得上又不至于空转磁盘
    private let interval: TimeInterval

    init(bus: FrameBus, interval: TimeInterval = 0.045) {
        self.bus = bus
        self.interval = interval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 先只看属性，变了才读内容 —— 不然每 45ms 白读一张几百 KB 的图
                if let snap = AppGroupBridge.snapshot(), snap != self.last {
                    self.last = snap
                    if let jpeg = AppGroupBridge.readFrame(), jpeg.count > 1_000 {
                        self.bus.publish(jpeg)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        last = nil
    }
}

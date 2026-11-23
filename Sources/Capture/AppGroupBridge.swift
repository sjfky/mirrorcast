import Foundation

// MARK: - App Group 帧桥
//
// 整机镜像只能由录屏扩展（Broadcast Upload Extension）拿到，而扩展是独立进程、
// 有自己的内存上限，不适合再塞一个 HTTP 服务端。所以：
//   扩展进程：ReplayKit 采样 → 编码 JPEG → 原子写 frame.jpg
//   App 进程：轮询 frame.jpg 的 mtime/size → 变化就 publish 进 FrameBus
// 用文件而不是 XPC，是因为扩展随时会被系统杀掉，文件桥最笨也最不容易漏。

enum AppGroupBridge {
    static let identifier = "group.com.example.mirrorcast"
    static let frameFileName = "frame.jpg"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var frameURL: URL? { container?.appendingPathComponent(frameFileName) }

    // MARK: HLS 发布目录（DLNA 实时流）

    /// 扩展写、App 读。这里只放"已经完整发布"的文件：
    /// init.mp4 / stream.m3u8 / fr-<n>.m4s
    static let hlsDirectoryName = "live"
    /// 主 App 写这个开关，扩展起来时读它 —— 避免默认就开重编码（费电费 CPU）
    static let hlsFlagFileName = "live.enabled"

    static var hlsDirectory: URL? {
        guard let base = container else { return nil }
        let dir = base.appendingPathComponent(hlsDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 会话文件（中间态）目录，扩展专用
    static var hlsScratchDirectory: URL? {
        guard let base = container else { return nil }
        let dir = base.appendingPathComponent("live-scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var liveEnabled: Bool {
        get {
            guard let url = container?.appendingPathComponent(hlsFlagFileName) else { return false }
            return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        set {
            guard let url = container?.appendingPathComponent(hlsFlagFileName) else { return }
            try? (newValue ? "1" : "0").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 扩展侧调用：原子覆盖写。半截 JPEG 会让接收端显示一条灰带。
    static func writeFrame(_ jpeg: Data) {
        guard let url = frameURL else { return }
        try? jpeg.write(to: url, options: [.atomic])
    }

    struct Snapshot: Equatable {
        var modified: Date
        var size: Int
    }

    static func snapshot() -> Snapshot? {
        guard let url = frameURL,
              let values = try? url.resourceValues(forKeys: [
                  .contentModificationDateKey, .fileSizeKey,
              ]) else { return nil }
        guard let modified = values.contentModificationDate else { return nil }
        return Snapshot(modified: modified, size: values.fileSize ?? 0)
    }

    static func readFrame() -> Data? {
        guard let url = frameURL else { return nil }
        return try? Data(contentsOf: url, options: [.uncached, .mappedIfSafe])
    }

    static func clear() {
        guard let url = frameURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}


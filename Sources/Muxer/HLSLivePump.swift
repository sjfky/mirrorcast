import Foundation

// MARK: - HLS 落盘泵
//
// 把复用器切出来的片段写成 App Group 目录里的文件，供主 App 的 HTTP 服务读取。
// 只用 FileManager，不碰任何系统框架 —— 因此和复用器一样能在 Linux 上编译。
//
// 为什么走文件而不是共享内存：广播扩展随时会被系统回收，
// 文件桥最笨，但崩溃/回收之后主 App 不会读到半截状态，
// 顶多多发一个已完成的分片。

final class HLSLivePump {
    let directory: URL
    private(set) var wroteInit = false
    private(set) var segmentCount = 0
    private var lastInitBytes: Data?

    static let initFileName = "init.mp4"
    static let playlistName = "stream.m3u8"

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
    }

    static func segmentName(_ index: UInt64) -> String { "fr-\(index).m4s" }

    /// init section 只在**内容变化**时重写（横竖屏切换会让 avcC 变）。
    /// 返回是否写了。
    @discardableResult
    func publishInitIfNeeded(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return false }
        if wroteInit, bytes == lastInitBytes { return false }
        writeAtomically(bytes, to: directory.appendingPathComponent(Self.initFileName))
        lastInitBytes = bytes
        wroteInit = true
        return true
    }

    /// 顺序很关键：**先写分片，再写播放列表**。
    /// 反了会让播放器从列表里拉到一个还不存在的文件 → UPnP 716 / 直接卡住。
    func publishSegment(index: UInt64, bytes: Data, playlist: String) {
        guard !bytes.isEmpty else { return }
        writeAtomically(bytes, to: directory.appendingPathComponent(Self.segmentName(index)))
        segmentCount += 1
        writePlaylist(playlist)
    }

    func writePlaylist(_ text: String) {
        writeAtomically(Data(text.utf8), to: directory.appendingPathComponent(Self.playlistName))
    }

    /// 删掉窗口以外的旧分片（广播每次能跑出几百个文件，不清理会吃掉几百 MB）
    func pruneSegments(keepFromIndexFrom index: UInt64) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in items where name.hasPrefix("fr-") && name.hasSuffix(".m4s") {
            let digits = name.dropFirst(3).dropLast(4)
            guard let n = UInt64(digits) else { continue }
            // 留 2 片余量：正好卡在边界的分片可能还有请求在飞
            if n + 2 < index { try? fm.removeItem(atPath: directory.appendingPathComponent(name).path) }
        }
    }

    /// 新一轮广播开始前清空，避免电视拉到上一轮断掉的时间轴
    func reset() {
        wroteInit = false
        lastInitBytes = nil
        segmentCount = 0
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in items { try? fm.removeItem(at: f) }
        }
    }

    var stats: String { "init=\(wroteInit ? "yes" : "no") 分片=\(segmentCount)" }

    private func writeAtomically(_ data: Data, to url: URL) {
        do {
            // .atomic = 写临时文件再 rename，读侧永远看不到半个文件
            try data.write(to: url, options: [.atomic])
        } catch {
            NSSLog("[HLS] 写 \(url.lastPathComponent) 失败: \(error.localizedDescription)")
        }
    }
}

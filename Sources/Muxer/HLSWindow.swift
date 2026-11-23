import Foundation

// MARK: - HLS 滑动窗口与播放列表
//
// 两条来路都要这个东西：
//   · FragmentedMP4Splitter.ingest  （自建 fMP4 / 增长文件）
//   · HLSSegmentWriter              （每段一个 AVAssetWriter）
// 所以窗口和 m3u8 文本只在这里实现一遍，别写两份。

struct PublishedSegment {
    let index: UInt64
    let duration: Double
    var fileName: String { "fr-\(index).m4s" }
}

final class HLSWindow {
    let keepSegments: Int
    let initFileName: String

    private var items: [PublishedSegment] = []

    var nextIndex: UInt64 { items.last.map { $0.index + 1 } ?? 0 }
    var window: [PublishedSegment] { items }
    /// 窗口内可见的分片
    var segments: [PublishedSegment] { items }
    /// 已被移出窗口的分片上界，App 侧据此删文件
    var prunedUpperBound: UInt64 { items.first?.index ?? 0 }
    var isEmpty: Bool { items.isEmpty }

    init(keepSegments: Int = 6, initFileName: String = "init.mp4") {
        self.keepSegments = max(3, keepSegments)
        self.initFileName = initFileName
    }

    /// 登记一个新分片，返回分配给它的序号
    @discardableResult
    func notePublished(duration: Double) -> UInt64 {
        let index = nextIndex
        items.append(PublishedSegment(index: index,
                                      duration: max(0.001, min(600, duration))))
        while items.count > keepSegments { items.removeFirst() }
        return index
    }

    func reset() { items.removeAll() }

    /// EXT-X-TARGETDURATION 必须是**整数**且 ≥ 窗口内最长分片，
    /// 否则严格一点的接收端（FFmpeg 系）直接判定列表非法。
    var targetDuration: Int { max(1, Int(ceil(items.map { $0.duration }.max() ?? 1))) }

    func playlist() -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",                     // EXT-X-MAP 需要 v7 起
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(prunedUpperBound)",
            "#EXT-X-MAP:URI=\"\(initFileName)\"",
        ]
        for s in items {
            lines.append("#EXTINF:\(String(format: "%.3f", s.duration)),")
            lines.append(s.fileName)
        }
        lines.append("")
        // 绝不写 #EXT-X-ENDLIST：写了就是点播，播放器拉完最后一片就不再回来要新的
        return lines.joined(separator: "\n")
    }
}

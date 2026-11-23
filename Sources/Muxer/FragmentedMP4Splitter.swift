import Foundation

// MARK: - 增长中的 fMP4 文件 → 完整分片
//
// AVAssetWriter 设了 movieFragmentInterval 之后，会把 fMP4 **原地追加**写进一个文件：
//   ftyp + moov + (styp? + moof + mdat) + (styp? + moof + mdat) + …
// 我们要做的是：摘出开头的 init section，再把后面每个 moof/mdat 组切成一个分片。
//
// 为什么自己拆：AVAssetWriter 没有"分片写完"的回调，只能读文件。
// 而"读一个还在被写的文件 + 按 box 边界切"是纯算术，
// 所以本类不依赖任何系统框架，能在 Linux 上拿真字节流跑单测。

struct MP4FragmentSlice {
    var index: UInt64       // 从 0 递增，直接对应 fr-<index>.m4s
    var bytes: Data
    var duration: Double
}

final class FragmentedMP4Splitter {
    struct TopBox {
        var type: String
        var start: Int
        var length: Int
    }

    private(set) var initSection: Data?
    private let window: HLSWindow
    var nextIndex: UInt64 { window.nextIndex }
    /// 媒体 timescale：Apple 的 writer 常见 600/1000，我们的自建复用器用 90000。
    /// 只影响 TARGETDURATION 取整，不影响可播放性。
    let mediaTimescale: Double

    init(keepSegments: Int = 6, mediaTimescale: Double = 90_000, keepSeconds: Double = 0) {
        self.window = HLSWindow(keepSegments: keepSegments)
        self.mediaTimescale = mediaTimescale > 0 ? mediaTimescale : 90_000
        _ = keepSeconds
    }

    /// 摄入文件当前的全部字节。
    /// **必须幂等**：调用方会在 writer 每次进度更新时重复调用，
    /// 同一个分片只能向外发一次，否则播放列表里会出现重复条目、序号疯涨。
    func ingest(_ file: Data) -> [MP4FragmentSlice] {
        let boxes = Self.topLevelBoxes(file)
        guard !boxes.isEmpty else { return [] }

        // 1) init section：第一个 styp/moof 之前的所有顶层 box
        let firstFragBox = boxes.firstIndex(where: { $0.type == "moof" || $0.type == "styp" })
        if initSection == nil, let idx = firstFragBox {
            var data = Data()
            for b in boxes[0..<idx] { data.append(file, at: b.start, length: b.length) }
            if !data.isEmpty { initSection = data }
        }
        guard let startIdx = firstFragBox else { return [] }

        // 2) 分组：新组边界 = styp，或在已有 mdat 之后再来的 moof。
        //    groupStart 必须从**第一个分片 box** 起算，写成 0 会把 ftyp+moov 裹进第 0 片。
        var groups: [(start: Int, end: Int, duration: Double)] = []
        var groupStart = boxes[startIdx].start
        var sawMDAT = false
        var sawMOOF = false
        var duration: Double = 0
        for b in boxes[startIdx...] {
            switch b.type {
            case "styp":
                if sawMOOF, sawMDAT {
                    groups.append((groupStart, b.start, duration))
                    sawMOOF = false; sawMDAT = false; duration = 0
                }
                groupStart = b.start
            case "moof":
                if sawMOOF, sawMDAT {
                    groups.append((groupStart, b.start, duration))
                    sawMOOF = false; sawMDAT = false; duration = 0
                    groupStart = b.start
                }
                sawMOOF = true
                var box = Data()
                box.append(file, at: b.start, length: b.length)
                duration = Self.trunDuration(box, timescale: mediaTimescale)
            case "mdat":
                sawMDAT = true
            case "emsg", "free", "skip":
                // 分片之间的旁路 box（Apple 偶尔在 mdat 后插 emsg/free）：归进当前组
                break
            default:
                break
            }
            // 走到文件末尾时，若该组已含 moof+mdat，就地闭合
            if b.start + b.length >= boxes.last!.start + boxes.last!.length,
               sawMOOF, sawMDAT {
                groups.append((groupStart, b.start + b.length, duration))
                sawMOOF = false; sawMDAT = false; duration = 0
            }
        }

        // 3) 幂等的关键：一个组**只有完整才会出现在 groups 里**，
        //    而且一旦出现就永远在那儿 —— 所以组在数组里的下标就是它的稳定序号。
        //    于是"只发没发过的"等价于 groups[nextIndex...]，不需要记录偏移量，
        //    也不怕窗口裁剪（published 只管播放列表窗口，与序号无关）。
        let done = Int(window.nextIndex)
        guard groups.count > done else { return [] }
        var out: [MP4FragmentSlice] = []
        for g in groups[done...] {
            var bytes = Data()
            bytes.append(file, at: g.start, length: g.end - g.start)
            guard bytes.containsTopLevelBox("moof"), bytes.containsTopLevelBox("mdat") else { continue }
            let idx = window.notePublished(duration: g.duration)
            out.append(MP4FragmentSlice(index: idx, bytes: bytes, duration: g.duration))
        }
        return out
    }

    var currentPlaylist: String { window.playlist() }

    /// 已被移出窗口的分片上界，App 侧据此删磁盘上的旧分片
    var prunedUpperBound: UInt64 { window.prunedUpperBound }

    func reset() {
        initSection = nil
        window.reset()
    }

    var stats: String { "init=\(initSection?.count ?? 0)B 已发=\(window.nextIndex) 窗口=\(window.segments.count)" }

    /// 一个**已经写完**的文件（例如 AVAssetWriter finish 之后的分片文件）里
    /// 抽出 init section 和全部媒体分片。写完的文件尺寸都是终值，
    /// 不需要 ingest 那套"怕读到半截"的保守逻辑。
    static func extractInitAndFragments(_ file: Data) -> (init: Data, fragments: [Data]) {
        let boxes = topLevelBoxes(file)
        guard let first = boxes.firstIndex(where: { $0.type == "moof" || $0.type == "styp" }) else {
            var all = Data(); for b in boxes { all.append(file, at: b.start, length: b.length) }
            return (all, [])
        }
        var initBytes = Data()
        for b in boxes[0..<first] { initBytes.append(file, at: b.start, length: b.length) }
        var fragments: [Data] = []
        var groupStart = boxes[first].start
        var sawMOOF = false, sawMDAT = false
        for b in boxes[first...] {
            switch b.type {
            case "styp":
                if sawMOOF, sawMDAT { fragments.append(slice(file, groupStart, b.start - groupStart)) }
                groupStart = b.start; sawMOOF = false; sawMDAT = false
            case "moof":
                if sawMOOF, sawMDAT {
                    fragments.append(slice(file, groupStart, b.start - groupStart))
                    groupStart = b.start
                }
                sawMOOF = true
            case "mdat": sawMDAT = true
            default: break
            }
            if b.start + b.length >= (boxes.last?.start ?? 0) + (boxes.last?.length ?? 0),
               sawMOOF, sawMDAT {
                fragments.append(slice(file, groupStart, b.start + b.length - groupStart))
            }
        }
        return (initBytes, fragments)
    }

    static func slice(_ file: Data, _ start: Int, _ length: Int) -> Data {
        var d = Data(); d.append(file, at: start, length: length); return d
    }

    // MARK: box 走查

    /// 扫描顶层 box 表。遇到任何"长度不可信/尾部不完整"立即停止 —— 
    /// 这正是我们只发已完成分片的依据。
    static func topLevelBoxes(_ file: Data) -> [TopBox] {
        var boxes: [TopBox] = []
        var offset = 0
        while offset < file.count {
            guard offset + 8 <= file.count else { break }
            let size = Int(file.u32(offset))
            let type = file.str4(offset + 4)
            var header = 8
            var length = size
            if size == 1 {
                guard offset + 16 <= file.count else { break }
                let big = file.u64(offset + 8)
                guard big >= 16, big < 0x7FFF_FFFF_FFFF else { break }
                length = Int(big)
                header = 16
            }
            guard length >= header, offset + length <= file.count else { break }   // 未写完
            boxes.append(TopBox(type: type, start: offset, length: length))
            offset += length
        }
        return boxes
    }

    /// trun 里 sample_duration 求和。
    /// 只用于 TARGETDURATION，读不到就返回 0，绝不去猜。
    static func trunDuration(_ moof: Data, timescale: Double) -> Double {
        guard let r = moof.range(of: Data([0x74, 0x72, 0x75, 0x6E])) else { return 0 }   // "trun"
        var p = r.upperBound
        guard p + 8 <= moof.count else { return 0 }
        let flags = Int(moof.u24(p + 1))
        p += 4
        let count = Int(moof.u32(p)); p += 4
        if flags & 0x000001 != 0, p + 4 <= moof.count { p += 4 }     // data_offset
        guard flags & 0x000100 != 0 else { return 0 }                // 没有 per-sample duration
        var total: Double = 0
        for _ in 0..<count {
            if p + 4 > moof.count { break }
            total += Double(moof.u32(p)); p += 4
            if flags & 0x000200 != 0 { p += 4 }
            if flags & 0x000400 != 0 { p += 4 }
            if flags & 0x000800 != 0 { p += 4 }
        }
        return total / max(1, timescale)
    }
}

private extension Data {
    mutating func append(_ other: Data, at offset: Int, length: Int) {
        guard offset >= 0, length > 0, offset + length <= other.count else { return }
        append(other.subdata(in: other.startIndex + offset ..< other.startIndex + offset + length))
    }

    func u32(_ at: Int) -> UInt32 {
        let i = startIndex + at
        guard i >= 0, i + 4 <= endIndex else { return 0 }
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16)
             | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }

    func u24(_ at: Int) -> UInt32 {
        let i = startIndex + at
        guard i >= 0, i + 3 <= endIndex else { return 0 }
        return (UInt32(self[i]) << 16) | (UInt32(self[i + 1]) << 8) | UInt32(self[i + 2])
    }

    func u64(_ at: Int) -> UInt64 {
        let i = startIndex + at
        guard i >= 0, i + 8 <= endIndex else { return 0 }
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(self[i + k]) }
        return v
    }

    func str4(_ at: Int) -> String {
        let i = startIndex + at
        guard i >= 0, i + 4 <= endIndex else { return "" }
        return String(decoding: self[i..<(i + 4)], as: UTF8.self)
    }

    /// 校验这段字节里确实含某个顶层 box（用于确认分片闭合）
    func containsTopLevelBox(_ type: String) -> Bool {
        FragmentedMP4Splitter.topLevelBoxes(self).contains { $0.type == type }
    }
}

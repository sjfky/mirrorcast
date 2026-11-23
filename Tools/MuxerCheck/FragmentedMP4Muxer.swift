import Foundation

// MARK: - 对外数据结构（**不含任何 CoreMedia 类型**）
//
// 这么设计是为了让这个文件能用 Linux 的 swiftc 单独编译、单独验证：
// iOS 侧的胶水把 CMSampleBuffer / CMVideoFormatDescription 转成下面的
// VideoSample / AVCConfig，容器逻辑本身完全不碰系统框架。

struct AVCConfig {
    /// 不含起始码，但**含** NAL 头字节
    var sps: [UInt8]
    var pps: [UInt8]
    var naluLengthSize: Int = 4
    /// 留空则从 SPS 解析
    var width: Int?
    var height: Int?
    var name: String = "MirrorCast"

    var parsedSPS: SPSInfo? { H264.parseSPS(Array(sps.dropFirst())) }
}

struct VideoSample {
    /// 该帧所有 NAL，每个前面带 naluLengthSize 字节的大端长度（AVCC 形式，无起始码）
    var avcc: [UInt8]
    var dts: Int64
    var pts: Int64
    var duration: Int64
    var isSync: Bool
}

// MARK: - 复用器

final class FragmentedMP4Muxer {
    struct Fragment {
        var sequence: UInt64        // 全局片段序号，文件名固定 fr-<seq>.m4s
        var mediaSequence: UInt64   // 播放列表窗口第一个序号
        var bytes: [UInt8]
        var duration: Double
        var playlist: String
    }

    enum MuxError: Error, CustomStringConvertible {
        case badSPS
        case noSamples
        case tooLarge(Int)
        var description: String {
            switch self {
            case .badSPS:     return "SPS 解析不出分辨率，无法生成 init section"
            case .noSamples:  return "片段里没有采样"
            case .tooLarge(let n): return "片段 \(n) 字节超过 32 位 box 上限，缩短分片时长"
            }
        }
    }

    let config: AVCConfig
    let timescale: Int64
    let targetDurationSeconds: Double
    
    private let trackID: UInt32 = 1
    /// 序号、窗口、播放列表全部交给 HLSWindow，避免和 splitter/segment writer 各写一套
    private var windowInstance = HLSWindow(keepSegments: 6)
    private var window: HLSWindow { windowInstance }
    var nextSequence: UInt64 { window.nextIndex }

    private var pending: [VideoSample] = []
    /// 第一个关键帧之前不能起流，之后**永远不丢帧**
    private var seenFirstSync = false
    private var pendingDuration: Int64 = 0
    private var cachedInit: [UInt8]?
    private let width: Int
    private let height: Int

    init(config: AVCConfig,
         timescale: Int64 = 90_000,
         segmentSeconds: Double = 1.5,
         keepSegments: Int = 6) throws {
        // keepSegments 由外部 windowInstance(keepSegments:) 传入的构造参数决定
        
        let info = config.parsedSPS
        guard let w = config.width ?? info?.width,
              let h = config.height ?? info?.height,
              w > 0, h > 0 else { throw MuxError.badSPS }
        self.config = config
        self.width = w
        self.height = h
        self.timescale = max(1, timescale)
        self.targetDurationSeconds = max(0.4, min(10.0, segmentSeconds))
        self.windowInstance = HLSWindow(keepSegments: keepSegments)
    }

    var pixelSize: (width: Int, height: Int) { (width, height) }

    // MARK: init section = ftyp + moov

    func initSegment() -> [UInt8] {
        if let cached = cachedInit { return cached }
        var w = ByteWriter()
        w.raw(Box("ftyp") { f in
            f.raw(ascii("isom"))
            f.be32(0x200)
            f.raw(ascii("iso5")); f.raw(ascii("avc1")); f.raw(ascii("mp41"))
        }.bytes)
        w.raw(buildMoov())
        cachedInit = w.data
        return w.data
    }

    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func buildMoov() -> [UInt8] {
        let stsd = Box("stsd") { b in
            b.raw(fullBoxHeader(version: 0, flags: 0))
            b.be32(1)
            b.raw(avc1SampleEntry())
        }.bytes

        let stbl = Box("stbl") { b in
            b.raw(stsd)
            // 分片文件里这几张表必须**存在且为空** —— 缺表的话 FFmpeg 的
            // mov demuxer 会报 "missing 'stsz'"/"malformed"，DLNA 端表现为拉不到流
            b.raw(Box("stts") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0)); x.be32(0)
            }.bytes)
            b.raw(Box("stsc") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0)); x.be32(0)
            }.bytes)
            b.raw(Box("stsz") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0))
                x.be32(0)     // sample_size = 0 → 逐样本长度在 trun 里给
                x.be32(0)     // sample_count
            }.bytes)
            b.raw(Box("stco") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0)); x.be32(0)
            }.bytes)
        }.bytes

        let dinf = Box("dinf") { b in
            b.raw(Box("dref") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0))
                x.be32(1)
                x.raw(Box("url ") { y in y.raw(fullBoxHeader(version: 0, flags: 1)) }.bytes)
            }.bytes)
        }.bytes

        let minf = Box("minf") { b in
            b.raw(Box("vmhd") { x in
                x.raw(fullBoxHeader(version: 0, flags: 1))   // has_effects
                x.be16(0)                                     // graphicsmode
                x.be16(0); x.be16(0); x.be16(0)               // opcolor
            }.bytes)
            b.raw(dinf)
            b.raw(stbl)
        }.bytes

        let mdia = Box("mdia") { b in
            b.raw(Box("mdhd") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0))
                x.be32(0); x.be32(0)                 // creation / modification time
                x.be32(UInt32(timescale))
                x.be32(0)                            // duration：直播未知
                x.be16(0x55C4)                       // language 'und'
                x.be16(0)                            // pre_defined
            }.bytes)
            b.raw(Box("hdlr") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0))
                x.be32(0)                            // pre_defined
                x.raw(ascii("vide"))                 // handler_type
                x.be32(0); x.be32(0); x.be32(0)      // reserved[3]
                x.raw(Array(config.name.utf8) + [0]) // name，必须以 0 结尾
            }.bytes)
            b.raw(minf)
        }.bytes

        let trak = Box("trak") { b in
            b.raw(Box("tkhd") { x in
                // v0：duration 是 **32 位**（v1 才是 64 位），这里按 v0 逐字段对齐
                x.raw(fullBoxHeader(version: 0, flags: 3))   // enabled|inMovie
                x.be32(0); x.be32(0)                          // creation / modification
                x.be32(trackID)
                x.be32(0)                                     // reserved
                x.be32(0)                                     // duration
                x.be32(0); x.be32(0)                          // reserved2[2]
                x.be16(0)                                     // layer
                x.be16(0)                                     // alternate_group
                x.be16(0x0100)                                // volume = 1.0 (8.8)
                x.be16(0)                                     // reserved
                x.raw(matrixIdentity())
                x.fixed16(Double(width))
                x.fixed16(Double(height))
            }.bytes)
            b.raw(mdia)
        }.bytes

        return Box("moov") { b in
            b.raw(Box("mvhd") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0))
                x.be32(0); x.be32(0)                  // creation / modification
                x.be32(UInt32(timescale))
                x.be32(0)                             // duration
                x.be32(0x0001_0000)                   // rate = 1.0 (16.16)
                x.be16(0x0100)                        // volume = 1.0 (8.8)
                x.be16(0)                             // reserved
                x.be32(0); x.be32(0)                  // reserved[2] (8 字节)
                x.raw(matrixIdentity())
                for _ in 0..<6 { x.be32(0) }          // predefined[6]
                x.be32(trackID + 1)                   // next_track_ID
            }.bytes)
            b.raw(trak)
            b.raw(Box("mvex") { x in
                x.raw(Box("trex") { t in
                    t.raw(fullBoxHeader(version: 0, flags: 0))
                    t.be32(trackID)
                    t.be32(0)      // default_sample_description_index
                    t.be32(0)      // default_sample_duration → 全部在 trun 显式给
                    t.be32(0)      // default_sample_size
                    t.be32(0)      // default_sample_flags
                }.bytes)
            }.bytes)
        }.bytes
    }

    /// identity 矩阵：2.30 / 16.16 / 2.30 混排，最后一格是 u 分量
    private func matrixIdentity() -> [UInt8] {
        var w = ByteWriter()
        w.be32(0x0001_0000); w.be32(0); w.be32(0)
        w.be32(0); w.be32(0x0001_0000); w.be32(0)
        w.be32(0); w.be32(0); w.be32(0x4000_0000)
        return w.data
    }

    private func avcC() -> [UInt8] {
        let info = config.parsedSPS
        let lenSize = max(1, min(4, config.naluLengthSize))
        func byte(_ i: Int, _ fallback: UInt8) -> UInt8 { config.sps.count > i ? config.sps[i] : fallback }
        var w = ByteWriter()
        w.u8(1)                                                        // configurationVersion
        w.u8(info?.profileIdc ?? byte(1, 0x64))                        // AVCProfileIndication
        w.u8(info?.avcProfileCompatibility ?? byte(2, 0x00))
        w.u8(info?.levelIdc ?? byte(3, 0x28))
        w.u8(UInt8(0xFC | (lenSize - 1)))                              // 11111 + lengthSizeMinusOne
        w.u8(UInt8(0xE0 | 1))                                          // 111 + numOfSPS
        w.be16(UInt16(config.sps.count)); w.raw(config.sps)
        w.u8(1)                                                        // numOfPPS
        w.be16(UInt16(config.pps.count)); w.raw(config.pps)
        return w.data
    }

    /// avc1 sample entry：78 字节固定部分 + avcC
    private func avc1SampleEntry() -> [UInt8] {
        Box("avc1") { b in
            for _ in 0..<6 { b.u8(0) }                  // reserved
            b.be16(1)                                   // data_reference_index
            b.be16(0)                                   // pre_defined
            b.be16(0)                                   // reserved
            b.be32(0); b.be32(0); b.be32(0)             // pre_defined[3]
            b.be16(UInt16(width)); b.be16(UInt16(height))
            b.be32(0x0048_0000)                         // horizresolution 72dpi
            b.be32(0x0048_0000)                         // vertresolution
            b.be32(0)                                   // reserved
            b.be16(1)                                   // frame_count
            b.raw([UInt8](repeating: 0, count: 32))     // compressorname
            b.be16(0x0018)                              // depth = 24
            b.be16(UInt16(bitPattern: -1))              // pre_defined = -1
            // 刻意不写 colr：色彩原信息已经在真 SPS 的 VUI 里。
            // 写死一个 BR<> 会把非 BT.709 的源标错，电视跟着错校色。
            b.raw(Box("avcC") { x in x.raw(self.avcC()) }.bytes)
        }.bytes
    }

    // MARK: 采样与切片

    /// 追加一帧。返回非 nil 表示刚裁出一个完整片段。
    ///
    /// 分片只落在关键帧上（否则电视加入播放列表后解不出来），但**判定切片的时机**
    /// 是"已超过目标时长且当前帧是关键帧"。绝对不要写成"片段必须以关键帧开始，
    /// 否则丢弃"—— 那样当编码器 GOP 比目标分片长时，会把整段 GOP 中间全丢光，
    /// 表现为画面每 2 秒跳一下。要分片对得齐，正确做法是把编码器的关键帧间隔
    /// 设成 ≈ segmentSeconds（见 VideoToolkitEncoder 的 MaxKeyframeInterval）。
    func append(_ sample: VideoSample) throws -> Fragment? {
        if !seenFirstSync {
            guard sample.isSync else { return nil }     // 只丢首个关键帧之前的
            seenFirstSync = true
        }

        // 判定顺序很关键：**先收段、再把这一帧当作新段的第一样本**。
        // 反过来（先塞进去再判长度）会把新 GOP 的关键帧算进上一段尾巴，
        // 于是新段以非同步帧开头 —— 电视中途加入播放列表时前一段整段解不出来。
        var done: Fragment?
        if sample.isSync,
           Double(pendingDuration) / Double(timescale) >= targetDurationSeconds {
            done = try cutFragment()
        }
        pending.append(sample)
        pendingDuration += max(1, sample.duration)
        return done
    }

    /// 广播结束时把尾巴刷出去
    func flush() throws -> Fragment? {
        guard !pending.isEmpty else { return nil }
        return try cutFragment()
    }

    private func cutFragment() throws -> Fragment {
        guard !pending.isEmpty else { throw MuxError.noSamples }
        let duration = Double(pendingDuration) / Double(timescale)
        let seq = window.notePublished(duration: duration)     // 序号在这里分配
        let bytes = try buildFragment(samples: pending, sequence: seq)
        pending.removeAll(keepingCapacity: true)
        pendingDuration = 0
        return Fragment(sequence: seq,
                        mediaSequence: window.prunedUpperBound,
                        bytes: bytes,
                        duration: duration,
                        playlist: window.playlist())
    }

    /// 闭式算出各 box 尺寸，data_offset **不需要回填/搜索**：
    /// trun 的 data_offset 相对 moof 起点（因为 tfhd 打开了 default-base-is-moof），
    /// 而 mdat 紧跟在 moof 之后，所以偏移 = moof 总长 + mdat 头 8 字节。
    private func buildFragment(samples: [VideoSample], sequence: UInt64) throws -> [UInt8] {
        let n = samples.count
        let payloadBytes = samples.reduce(0) { $0 + $1.avcc.count }
        guard n > 0, payloadBytes > 0 else { throw MuxError.noSamples }
        if payloadBytes + 8 > 0x0FFF_FFFF { throw MuxError.tooLarge(payloadBytes) }

        let mfhdBytes = 8 + 4 + 4                       // box头 + full + sequence_number
        let tfhdBytes = 8 + 4 + 4
        let tfdtBytes = 8 + 4 + 8
        let trunBytes = 8 + 4 + 4 + 4 + 12 * n          // 头 + full + count + data_offset + 样本表
        let trafBytes = 8 + tfhdBytes + tfdtBytes + trunBytes
        let moofBytes = 8 + mfhdBytes + trafBytes
        let dataOffset = UInt32(moofBytes + 8)

        var trun = ByteWriter()
        trun.raw(fullBoxHeader(version: 0, flags: 0x000701))   // data-offset|duration|size|flags
        trun.be32(UInt32(n))
        trun.be32(dataOffset)
        for s in samples {
            trun.be32(UInt32(max(1, s.duration)))
            trun.be32(UInt32(s.avcc.count))
            // 32 位 sample_flags：bit25..24 sample_depends_on，bit16 is_non_sync
            //   同步帧 0x02000000（depends_on=2），非同步 0x01010000（depends_on=1, non-sync=1）
            // 编码时关了 frame reordering → 无 B 帧 → pts==dts，
            // 所以不写 sample-composition-time-offsets，避开符号/无符号歧义
            trun.be32(s.isSync ? 0x0200_0000 : 0x0101_0000)
        }

        let firstDTS = UInt64(bitPattern: Int64(samples[0].dts))

        let traf = Box("traf") { b in
            b.raw(Box("tfhd") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0x020000))   // default-base-is-moof
                x.be32(trackID)
            }.bytes)
            b.raw(Box("tfdt") { x in
                x.raw(fullBoxHeader(version: 1, flags: 0))
                x.be64(firstDTS)
            }.bytes)
            b.raw(Box("trun") { x in x.raw(trun.data) }.bytes)
        }.bytes

        let moof = Box("moof") { b in
            b.raw(Box("mfhd") { x in
                x.raw(fullBoxHeader(version: 0, flags: 0))
                x.be32(UInt32(sequence & 0xFFFF_FFFF))
            }.bytes)
            b.raw(traf)
        }.bytes

        var mdat = ByteWriter()
        for s in samples { mdat.raw(s.avcc) }

        var out = ByteWriter()
        out.raw(Box("styp") { b in
            b.raw(ascii("iso6"))
            b.be32(0x200)
            b.raw(ascii("iso6")); b.raw(ascii("msdh")); b.raw(ascii("msix"))
        }.bytes)
        out.raw(moof)
        out.raw(Box("mdat") { $0.raw(mdat.data) }.bytes)
        return out.data
    }

    /// 播放列表（窗口已裁到 keepSegments 片）
    var currentPlaylist: String { window.playlist() }

    /// 已被移出窗口的分片上界
    var oldestRetainedSequence: UInt64 { window.prunedUpperBound }

    var stats: String {
        "seq=\(window.nextIndex) window=\(window.prunedUpperBound)..\(window.nextIndex) pending=\(pending.count) 帧/\(pendingDuration)/\(timescale)s"
    }
}

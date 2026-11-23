import Foundation

// MARK: - fragmented MP4 (ISO/IEC 14496-12) 复用器
//
// 目标：把 VideoToolbox 编码出来的 H.264 采样切成 HLS 的 fMP4 媒体片段，
// 让 DLNA 的 DMR 能拉一个**实时**流（http://手机IP/live/stream.m3u8）。
//
// 刻意只依赖 Foundation —— 不出现 CMVideoFormatDescription / CMSampleBuffer，
// iOS 侧的胶水层负责把 CoreMedia 的东西转成这里的 VideoSample / AVCConfig。
// 这样这个文件可以在 Linux 上用 swiftc 单独编译并喂给 ffprobe/PyAV 做结构验证，
// 而不必等一台 Mac。

// MARK: 字节写入

struct ByteWriter {
    private(set) var data: [UInt8] = []

    init(reserve: Int = 1 << 16) { data.reserveCapacity(reserve) }

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func be16(_ v: UInt16) {
        data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF))
    }

    mutating func be24(_ v: UInt32) {
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func be32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func be64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((v >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func raw(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func raw(_ bytes: ArraySlice<UInt8>) { data.append(contentsOf: bytes) }
    mutating func raw(_ data: Data) { data.withUnsafeBytes { raw in self.data.append(contentsOf: raw) } }

    /// 16.16 定点
    mutating func fixed16(_ value: Double) {
        let scaled = Int32((value * 65536.0).rounded())
        be32(UInt32(bitPattern: scaled))
    }

    /// 8.8 定点，用于 track volume
    mutating func fixed8(_ value: Double) {
        let scaled = Int16((value * 256.0).rounded())
        be16(UInt16(bitPattern: scaled))
    }

    var count: Int { data.count }

    func subdata(_ from: Int, _ to: Int) -> ArraySlice<UInt8> {
        data[from..<to]
    }
}

enum BoxFourCC {
    /// 4 字符 type 转 UInt32
    static func code(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for b in Array(s.utf8.prefix(4)) { v = (v << 8) | UInt32(b) }
        // 不足 4 字节按右侧补空格处理
        let missing = 4 - min(4, s.utf8.count)
        for _ in 0..<missing { v = v << 8 }
        return v
    }
}

/// 写一个 box：内容先落进临时 writer，回填 size 后拼接。
/// 全实现只走 size 字段（32 位）—— 直播分片都远小于 4GB，init 也小；
/// 用 64 位 largedir 反而会把一堆老固件的解析器绕晕。
struct Box {
    let type: String
    let payload: [UInt8]

    init(_ type: String, _ body: (inout ByteWriter) -> Void) {
        var w = ByteWriter()
        body(&w)
        self.type = type
        self.payload = w.data
    }

    var bytes: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 8)
        let size = UInt32(payload.count + 8)
        out.append(UInt8((size >> 24) & 0xFF))
        out.append(UInt8((size >> 16) & 0xFF))
        out.append(UInt8((size >> 8) & 0xFF))
        out.append(UInt8(size & 0xFF))
        for c in Array(type.utf8.prefix(4)) { out.append(c) }
        while out.count < 8 { out.append(0x20) }
        out.append(contentsOf: payload)
        return out
    }

    /// 嵌进父 box
    var payloadOnly: [UInt8] { bytes }
}

func fullBoxHeader(version: UInt8, flags: UInt32) -> [UInt8] {
    var w = ByteWriter()
    w.u8(version)
    w.be24(flags & 0x00FF_FFFF)
    return w.data
}

// MARK: - H.264 bitstream

/// Exp-Golomb 读位器，只为从 SPS 里抠出宽高 —— VideoToolbox 也给了这些值，
/// 但走 SPS 让复用器与编码器解耦（并且能在 Linux 上单独测）。
struct BitReader {
    private let bytes: [UInt8]
    private var pos = 0        // bit

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var bitPosition: Int { pos }

    mutating func u(_ n: Int) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<n {
            guard pos >> 3 < bytes.count else { break }
            let bit = (UInt32(bytes[pos >> 3]) >> UInt32(7 - (pos & 7))) & 1
            v = (v << 1) | bit
            pos += 1
        }
        return v
    }

    mutating func ue() -> UInt32 {
        var zeros = 0
        while pos >> 3 < bytes.count {
            let bit = (bytes[pos >> 3] >> UInt32(7 - (pos & 7))) & 1
            pos += 1
            if bit == 1 { break }
            zeros += 1
            if zeros > 32 { break }
        }
        guard zeros > 0 else { return 0 }
        return (1 << UInt32(zeros)) - 1 + u(zeros)
    }

    mutating func se() -> Int32 {
        let k = ue()
        if k & 1 == 1 { return Int32((k + 1) >> 1) }
        return -Int32(k >> 1)
    }

    mutating func moreData() -> Bool { pos >> 3 < bytes.count }
}

struct SPSInfo {
    var width: Int
    var height: Int
    var profileIdc: UInt8
    var constraintBytes: UInt8
    var levelIdc: UInt8
    var chromaFormatIdc: UInt32
    /// profile-compatibility 五元组，AV1/HEVC 之外 H.264 也按这个填 avcC
    var avcProfileCompatibility: UInt8 { constraintBytes }
}

enum H264 {
    static func nalType(_ header: UInt8) -> Int { Int(header & 0x1F) }

    /// 去仿真：把 00 00 03 里的 03 去掉，得到 RBSP
    static func rbsp(from nalBody: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(nalBody.count)
        var i = 0
        while i < nalBody.count {
            if i + 2 < nalBody.count, nalBody[i] == 0, nalBody[i + 1] == 0, nalBody[i + 2] == 3 {
                out.append(0); out.append(0)
                i += 3
            } else {
                out.append(nalBody[i])
                i += 1
            }
        }
        return out
    }

    /// 解析 SPS（输入是**不含 NAL 头字节**的 RBSP 或原始 NAL 体，本函数自己定位）
    static func parseSPS(_ nalBodyWithoutHeader: [UInt8]) -> SPSInfo? {
        let rbsp = rbsp(from: nalBodyWithoutHeader)
        guard rbsp.count >= 4 else { return nil }
        var r = BitReader(rbsp)
        let profile = UInt8(r.u(8))
        let constraint = UInt8(r.u(8))
        let level = UInt8(r.u(8))
        _ = r.ue()                                  // seq_parameter_set_id
        var chroma: UInt32 = 1
        var separate = true
        var bitDepthLuma: UInt32 = 8
        let qpprime: UInt32 = 26
        if profile == 100 || profile == 110 || profile == 122 || profile == 244
            || profile == 44 || profile == 83 || profile == 86 || profile == 118
            || profile == 128 || profile == 138 || profile == 139 || profile == 134 || profile == 135 {
            chroma = r.ue()
            if chroma == 3 { separate = r.u(1) == 1 }
            _ = r.u(1)                              // reserved_zero_2bits
            bitDepthLuma = r.ue() + 8
            let bitDepthChroma = r.ue() + 8
            _ = r.u(1)                              // qpprime_y_zero_transform_bypass_flag
            if r.u(1) == 1 {                        // seq_scaling_matrix_present
                let count = chroma != 3 ? 8 : 12
                for i in 0..<count {
                    if r.u(1) == 1 { scalingListSkip(&r, size: i < 6 ? 16 : 64) }
                }
            }
            _ = bitDepthChroma
        }
        _ = r.ue()                                  // log2_max_frame_num_minus4
        let picOrderCntType = r.ue()
        if picOrderCntType == 0 {
            _ = r.ue()                              // log2_max_pic_order_cnt_lsb_minus4
        } else if picOrderCntType == 1 {
            _ = r.u(1)
            _ = r.se(); _ = r.se(); _ = r.se()
            let cycles = Int(r.ue())
            for _ in 0..<cycles { _ = r.se() }
        }
        _ = r.ue()                                  // max_num_ref_frames —— 是 ue(v)，不是 u(1)
        _ = r.u(1)                                  // gaps_in_frame_num_value_allowed_flag
        let widthInMBS = Int(r.ue()) + 1
        let heightInMapUnits = Int(r.ue()) + 1
        let frameMBSOnly = r.u(1) == 1
        if !frameMBSOnly {
            // mb_adaptive_frame_field_flag **只在 frame_mbs_only_flag==0 时才存在**。
            // 无条件读一位会让后面所有字段整体错位一位，解出来的宽高变成乱数。
            _ = r.u(1)
        }
        _ = r.u(1)                                  // direct_8x8_inference_flag
        let frameCropping = r.u(1) == 1
        var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
        if frameCropping {
            cropLeft = Int(r.ue()); cropRight = Int(r.ue())
            cropTop = Int(r.ue()); cropBottom = Int(r.ue())
        }
        // 标准里的推导（H.264 表 6-1 / 7.4.3 的 frame_cropping 部分）：
        //   FrameHeightInMBS = (2 - frame_mbs_only_flag) * PicHeightInMapUnits
        //   CropUnitX = SubWidthC          CropUnitY = SubHeightC * (2 - frame_mbs_only_flag)
        // 4:2:0 与 4:2:2 的 SubWidthC/SubHeightC 都是 2，4:4:4 与单色是 1。
        // 之前写成"高度再乘一个 subHeightY"是错的，会把 720 行算成 1440。
        let frameHeightInMBS = (2 - (frameMBSOnly ? 1 : 0)) * heightInMapUnits
        let subWidthC = (chroma == 1 || chroma == 2) ? 2 : 1
        let subHeightC = (chroma == 1 || chroma == 2) ? 2 : 1
        let cropUnitX = subWidthC
        let cropUnitY = subHeightC * (2 - (frameMBSOnly ? 1 : 0))
        let width = widthInMBS * 16 - (cropLeft + cropRight) * cropUnitX
        let height = frameHeightInMBS * 16 - (cropTop + cropBottom) * cropUnitY
        _ = separate; _ = bitDepthLuma; _ = qpprime
        guard width > 0, height > 0 else { return nil }
        return SPSInfo(width: width, height: height,
                       profileIdc: profile, constraintBytes: constraint, levelIdc: level,
                       chromaFormatIdc: chroma)
    }

    /// 跳过一个 scaling_list：值域和 H.264 表 7-6 一致，这里只需要消耗正确位数
    private static func scalingListSkip(_ r: inout BitReader, size: Int) {
        var lastScale: Int32 = 8
        var nextScale: Int32 = 8
        for j in 0..<size {
            if nextScale != 0 {
                let delta = r.se()
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = (nextScale == 0) ? lastScale : nextScale
            _ = j
        }
    }

    /// Annex-B（带起始码）→ 单长度前缀 NAL 列表
    static func nalUnits(annexB: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var starts: [(index: Int, len: Int)] = []
        var i = 0
        while i + 2 < annexB.count {
            if annexB[i] == 0, annexB[i + 1] == 0, annexB[i + 2] == 1 {
                starts.append((i, 3)); i += 3; continue
            }
            if i + 3 < annexB.count, annexB[i] == 0, annexB[i + 1] == 0, annexB[i + 2] == 0, annexB[i + 3] == 1 {
                starts.append((i, 4)); i += 4; continue
            }
            i += 1
        }
        for (n, found) in starts.enumerated() {
            let bodyStart = found.index + found.len
            let bodyEnd = n + 1 < starts.count ? starts[n + 1].index : annexB.count
            // 去掉 trailing_zero_BITS / 尾部 0x80 之前的尾零
            var end = bodyEnd
            while end > bodyStart + 1, annexB[end - 1] == 0 { end -= 1 }
            if end > bodyStart { result.append(Array(annexB[bodyStart..<end])) }
        }
        return result
    }
}

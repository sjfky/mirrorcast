#!/usr/bin/env python3
"""对 FragmentedMP4Muxer 的输出做字节级独立校验。

用另一门语言把 box 结构解析一遍，专门查手写 MP4 最容易错的几处：
  * box size 是否自洽（任何一处长度算错，整条流就是"拉不到/黑屏"）
  * trun.data_offset 是否**正好**落在 mdat 第一个样本的第一字节
  * Σsample_size 是否等于 mdat 载荷长度
  * 相邻分片的 tfdt 是否等于 前一片 tfdt + 前一片 Σduration（时间轴不能断）
  * 每个样本是否都落在关键帧边界（分片首样本必须是 sync）
用法: python3 Tools/validate_mp4.py /tmp/fmp4test
"""
import os
import struct
import sys

BOX = 0


def parse_boxes(buf, start=0, end=None, depth=0, path=""):
    end = len(buf) if end is None else end
    out = []
    i = start
    while i < end:
        if i + 8 > end:
            raise AssertionError(f"{path}: 尾部残留 {end - i} 字节，不足一个 box 头")
        size, = struct.unpack(">I", buf[i:i + 4])
        btype = buf[i + 4:i + 8].decode("latin1")
        if size == 0:
            size = end - i
            header = 8
        elif size == 1:
            size, = struct.unpack(">Q", buf[i + 8:i + 16])
            header = 16
        else:
            header = 8
        if size < header:
            raise AssertionError(f"{path}/{btype}: size={size} 小于头部 {header}")
        if i + size > end:
            raise AssertionError(f"{path}/{btype}: size={size} 越界（剩 {end - i}）")
        out.append({"type": btype, "off": i, "size": size, "hdr": header,
                    "path": f"{path}/{btype}", "depth": depth,
                    "children": []})
        if btype in ("moov", "trak", "mdia", "minf", "stbl", "dinf", "mvex",
                     "moof", "traf", "avc1", "stsd", "edts"):
            body_start = i + header + (4 if btype in ("stsd",) else 0)
            if btype == "stsd":
                # stsd: full + entry_count，之后是若干 sample entry
                pass
            cur = i + header
            if btype == "stsd":
                version_flags = 4
                count, = struct.unpack(">I", buf[cur + version_flags:cur + version_flags + 4])
                cur += version_flags + 4
            elif btype in ("avc1",):
                cur += 6 + 2 + 2 + 2 + 12 + 2 + 2 + 4 + 4 + 4 + 2 + 32 + 2 + 2
                if cur > i + size:
                    raise AssertionError(f"{path}/avc1: 固定部分超过 78 字节，布局错")
            if btype == "stsd":
                # 手工按 entry 走
                entries = []
                while cur < i + size:
                    esz, = struct.unpack(">I", buf[cur:cur + 4])
                    etyp = buf[cur + 4:cur + 8].decode("latin1")
                    child = {"type": etyp, "off": cur, "size": esz, "hdr": 8,
                             "path": f"{path}/{btype}/{etyp}", "depth": depth + 1,
                             "children": []}
                    if etyp == "avc1":
                        child["children"] = parse_boxes(buf, cur + 8 + 78, cur + esz,
                                                        depth + 2, child["path"])
                    entries.append(child)
                    cur += esz
                out[-1]["children"] = entries
            else:
                out[-1]["children"] = parse_boxes(buf, cur, i + size, depth + 1, out[-1]["path"])
        i += size
    return out


def attach_buf(boxes, buf):
    for b in boxes:
        b["_buf"] = buf
        attach_buf(b["children"], buf)


def find(boxes, name):
    for b in boxes:
        if b["type"] == name:
            return b
        hit = find(b["children"], name)
        if hit:
            return hit
    return None


def full(b):
    buf = b["_buf"]
    ver = buf[b["off"] + b["hdr"]]
    flags = int.from_bytes(buf[b["off"] + b["hdr"] + 1:b["off"] + b["hdr"] + 4], "big")
    return ver, flags


def check_init(path):
    buf = open(path, "rb").read()
    tops = parse_boxes(buf)
    attach_buf(tops, buf)
    types = [t["type"] for t in tops]
    assert types[:2] == ["ftyp", "moov"], f"init 顶层应为 ftyp+moov，实际 {types}"
    moov = find(tops, "moov")
    mvhd = find([moov], "mvhd")
    ver, _ = full(mvhd)
    assert ver == 0 and mvhd["size"] == 108, f"mvhd v0 应为 108 字节，实际 {mvhd['size']}"
    trak = find([moov], "trak")
    tkhd = find([trak], "tkhd")
    ver, flags = full(tkhd)
    assert ver == 0 and tkhd["size"] == 92, f"tkhd v0 应为 92 字节，实际 {tkhd['size']}"
    w, h = struct.unpack(">II", buf[tkhd["off"] + tkhd["size"] - 8:tkhd["off"] + tkhd["size"]])
    print(f"  tkhd 尺寸 = {w / 65536:.0f}x{h / 65536:.0f}  flags={flags}")
    assert (w, h) == (1280 << 16, 720 << 16), "tkhd 宽高写错"
    mdhd = find([trak], "mdhd")
    assert mdhd["size"] == 32, f"mdhd v0 应为 32 字节，实际 {mdhd['size']}"
    ts, = struct.unpack(">I", buf[mdhd["off"] + mdhd["hdr"] + 4 + 8:mdhd["off"] + mdhd["hdr"] + 4 + 12])
    assert ts == 90000, f"mdhd timescale={ts}"
    stbl = find([trak], "stbl")
    order = [c["type"] for c in stbl["children"]]
    print("  stbl 顺序 =", order)
    assert order == ["stsd", "stts", "stsc", "stsz", "stco"], \
        f"stbl 子表必须齐全且顺序规范（FFmpeg 按出现顺序找）：{order}"
    for name in ("stts", "stsc", "stco"):
        box = [c for c in stbl["children"] if c["type"] == name][0]
        cnt, = struct.unpack(">I", buf[box["off"] + box["hdr"] + 4:box["off"] + box["hdr"] + 8])
        assert cnt == 0, f"{name} 的 entry_count 必须为 0，实际 {cnt}"
    sz = [c for c in stbl["children"] if c["type"] == "stsz"][0]
    sample_size, sample_count = struct.unpack(">II", buf[sz["off"] + sz["hdr"] + 4:sz["off"] + sz["hdr"] + 12])
    assert (sample_size, sample_count) == (0, 0), "stsz 必须 (0,0)"
    avc1 = find([stbl], "avc1")
    avcc = find([avc1], "avcC")
    body = buf[avcc["off"] + avcc["hdr"]:avcc["off"] + avcc["size"]]
    assert body[0] == 1, "configurationVersion 必须为 1"
    len_size = (body[4] & 0x03) + 1
    n_sps = body[5] & 0x1F
    assert n_sps == 1
    sps_len, = struct.unpack(">H", body[6:8])
    p = 8 + sps_len
    assert body[p] == 1, "numPPS 必须为 1"
    pps_len, = struct.unpack(">H", body[p + 1:p + 3])
    assert p + 3 + pps_len == len(body), f"avcC 长度不自洽: 算了 {p + 3 + pps_len} 实际 {len(body)}"
    print(f"  avcC: profile={body[1]} compat={body[2]} level={body[3]} lenSize={len_size} "
          f"sps={sps_len}B pps={pps_len}B")
    mvex = find([moov], "mvex")
    trex = find([mvex], "trex")
    assert trex is not None, "分片文件必须有 mvex/trex"
    d = struct.unpack(">IIIII", buf[trex["off"] + trex["hdr"] + 4:trex["off"] + trex["size"]])
    assert d == (1, 0, 0, 0, 0), f"trex 默认值应全 0（一切以 trun 为准），实际 {d}"
    return tops


def check_frag(path, prev, prev_is_last=None):
    buf = open(path, "rb").read()
    tops = parse_boxes(buf)
    attach_buf(tops, buf)
    types = [t["type"] for t in tops]
    assert types == ["styp", "moof", "mdat"], f"{os.path.basename(path)} 顶层 = {types}"
    moof, mdat = tops[1], tops[2]
    traf = find([moof], "traf")
    tfhd = find([traf], "tfhd")
    ver, flags = full(tfhd)
    assert flags & 0x020000, "tfhd 必须设 default-base-is-moof，否则 data_offset 基准不对"
    track_id, = struct.unpack(">I", buf[tfhd["off"] + tfhd["hdr"] + 4:tfhd["off"] + tfhd["hdr"] + 8])
    assert track_id == 1
    tfdt = find([traf], "tfdt")
    ver, _ = full(tfdt)
    assert ver == 1, "直播必须用 tfdt v1（64 位），32 位在长时间广播后会回绕"
    base, = struct.unpack(">Q", buf[tfdt["off"] + tfdt["hdr"] + 4:tfdt["off"] + tfdt["size"]])
    trun = find([traf], "trun")
    tver, tflags = full(trun)
    p = trun["off"] + trun["hdr"] + 4
    count, = struct.unpack(">I", buf[p:p + 4]); p += 4
    assert tflags & 0x01, "data-offset-present 没打开"
    data_offset, = struct.unpack(">I", buf[p:p + 4]); p += 4
    samples = []
    for _ in range(count):
        dur, sz2, fl = struct.unpack(">III", buf[p:p + 12]); p += 12
        samples.append((dur, sz2, fl))
    assert p == trun["off"] + trun["size"], "trun 解析没吃满，flags 与字段不匹配"
    # 关键：data_offset 相对 moof 起点
    target = moof["off"] + data_offset
    assert target == mdat["off"] + mdat["hdr"], \
        f"data_offset={data_offset} → 指向 {target}，但 mdat 载荷从 {mdat['off'] + mdat['hdr']} 开始"
    total = sum(s[1] for s in samples)
    assert total == mdat["size"] - mdat["hdr"], \
        f"Σsample_size={total} != mdat 载荷={mdat['size'] - mdat['hdr']}"
    assert trun["off"] + trun["size"] <= moof["off"] + moof["size"], "trun 越出 moof"
    # 首样本必须 sync
    first_flags = samples[0][2]
    if prev_is_last is None or not prev_is_last[0]:
        # 只有收尾 flush 出来的最后一片可能以非同步帧开头，中间的分片不行
        assert not (first_flags & 0x00010000), f"分片首样本 non-sync=1，电视加入后解不出来：{first_flags:#x}"
    for dur, _, fl in samples:
        assert dur > 0
    syncs = [i for i, s in enumerate(samples) if not (s[2] & 0x00010000)]
    sumdur = sum(s[0] for s in samples)
    if prev:
        prev_tfdt, prev_sum = prev
        assert base == prev_tfdt + prev_sum, \
            f"时间轴断裂: 本片 tfdt={base}, 应为 {prev_tfdt}+{prev_sum}={prev_tfdt + prev_sum}"
    print(f"  {os.path.basename(path)}: 样本={count} sync{syncs} tfdt={base} dur={sumdur} "
          f"mdat={mdat['size']}B data_offset 正确")
    return (base, sumdur)


def check_playlist(path):
    text = open(path).read()
    lines = [l for l in text.splitlines() if l]
    assert lines[0] == "#EXTM3U"
    assert "#EXT-X-ENDLIST" not in text, "直播列表绝不能有 ENDLIST"
    ver = int([l for l in lines if l.startswith("#EXT-X-VERSION")][0].split(":")[1])
    assert ver >= 7, "EXT-X-MAP 需要 version>=7"
    target = int([l for l in lines if l.startswith("#EXT-X-TARGETDURATION")][0].split(":")[1])
    seq = int([l for l in lines if l.startswith("#EXT-X-MEDIA-SEQUENCE")][0].split(":")[1])
    extinfs = [float(l.split(":")[1].rstrip(",")) for l in lines if l.startswith("#EXTINF")]
    worst = max(extinfs)
    assert worst <= target + 1e-9, f"EXTINF {worst} 超过 TARGETDURATION {target}，播放器会判定列表非法"
    segs = [l for l in lines if l.endswith(".m4s")]
    assert len(segs) == len(extinfs)
    assert '#EXT-X-MAP:URI="init.mp4"' in text
    print(f"  m3u8: version={ver} target={target} media_seq={seq} 分片={len(segs)} 最长={worst:.3f}s")
    return segs


if __name__ == "__main__":
    d = sys.argv[1] if len(sys.argv) > 1 else "/tmp/fmp4test"
    print("== init.mp4")
    check_init(os.path.join(d, "init.mp4"))
    print("== 分片")
    segs = check_playlist(os.path.join(d, "stream.m3u8"))
    # 窗口里的分片都在磁盘上
    prev = None
    frags = [n for n in os.listdir(d) if n.startswith("fr-") and n.endswith(".m4s")]
    frags = sorted(frags, key=lambda n: int(n[3:].split(".")[0]))
    for i, name in enumerate(frags):
        prev = check_frag(os.path.join(d, name), prev, (i == len(frags) - 1,))
    for s in segs:
        assert os.path.exists(os.path.join(d, s)), f"播放列表引用了不存在的 {s}"
    print("== 全部通过")

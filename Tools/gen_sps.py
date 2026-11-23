#!/usr/bin/env python3
"""生成一条最小可用的 H.264 baseline SPS（1280x720），用来在 Linux 上跨语言自校验
   Swift 位流解析器（写侧 Python / 读侧 Swift，两边独立实现，能对上就说明解析逻辑没错）。
   同时把 hex 打印出来给 muxcheck 用。"""


class BW:
    def __init__(self):
        self.bits = []

    def u(self, val, n):
        for i in range(n - 1, -1, -1):
            self.bits.append((val >> i) & 1)

    def ue(self, val):
        v = val + 1
        n = v.bit_length()
        self.u(0, n - 1)
        self.u(v, n)

    def se(self, val):
        self.ue(2 * val - 1 if val > 0 else -2 * val)

    def done(self):
        self.bits.append(1)          # rbsp_trailing_bits
        while len(self.bits) % 8:
            self.bits.append(0)
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            b = 0
            for j in range(8):
                b = (b << 1) | self.bits[i + j]
            out.append(b)
        return bytes(out)


def sps(width=1280, height=720):
    b = BW()
    profile, constraint, level = 66, 0xC0, 40       # baseline, L4.0
    b.u(profile, 8); b.u(constraint, 8); b.u(level, 8)
    b.ue(0)                                          # seq_parameter_set_id
    b.ue(0)                                          # log2_max_frame_num_minus4
    b.ue(0)                                          # pic_order_cnt_type
    b.ue(2)                                          # log2_max_pic_order_cnt_lsb_minus4
    b.ue(1)                                          # max_num_ref_frames
    b.u(0, 1)                                        # gaps_in_frame_num_value_allowed_flag
    b.ue(width // 16 - 1)                            # pic_width_in_mbs_minus1
    b.ue(height // 16 - 1)                           # pic_height_in_map_units_minus1
    b.u(1, 1)                                        # frame_mbs_only_flag
    b.u(1, 1)                                        # direct_8x8_inference_flag
    b.u(0, 1)                                        # frame_cropping_flag
    b.u(0, 1)                                        # vui_parameters_present_flag
    rbsp = b.done()
    return bytes([0x67]) + rbsp                      # NAL 头: nal_ref_idc=3, type=7


def pps():
    b = BW()
    b.ue(0)   # pic_parameter_set_id
    b.ue(0)   # seq_parameter_set_id
    b.u(0, 1)  # entropy_coding_mode_flag
    b.u(0, 1)  # bottom_field_pic_order_in_frame_present_flag
    b.ue(0)   # num_slice_groups_minus1
    b.ue(0)   # num_ref_idx_l0_default_active_minus1
    b.ue(0)   # num_ref_idx_l1_default_active_minus1
    b.u(0, 1)  # weighted_pred_flag
    b.u(0, 2)  # weighted_bipred_idc
    b.se(0)   # pic_init_qp_minus26
    b.se(0)   # pic_init_qs_minus26
    b.se(0)   # chroma_qp_index_offset
    b.u(0, 1)  # deblocking_filter_control_present_flag
    b.u(0, 1)  # constrained_intra_pred_flag
    b.u(0, 1)  # redundant_pic_cnt_present_flag
    return "68" + b.done().hex()


if __name__ == "__main__":
    s = sps()
    print(f'SPS hex = {s.hex()}  ({len(s)} 字节)')
    print(f'PPS hex = {pps()}')
    print(f'期望: 1280x720 profile=66 constraint=192 level=40')

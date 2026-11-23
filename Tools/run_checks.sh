#!/bin/bash
# 容器与 HLS 逻辑的自测（Linux / macOS 都可跑，不需要 Xcode）
# 覆盖：SPS 位流解析、fMP4 容器字节级校验、分片切片器幂等性、HLS 窗口与播放列表、旧片清理
set -euo pipefail
cd "$(dirname "$0")/.."

command -v swiftc >/dev/null || { echo "!! 没有 swiftc。macOS 装 Xcode 就有；Linux 见 https://swift.org/install"; exit 1; }

BIN=$(mktemp -d)/muxcheck
echo "› 编译测试台"
swiftc -O Tools/MuxerCheck/*.swift Sources/Muxer/*.swift Sources/Support/Log.swift -o "$BIN"

python3 Tools/gen_sps.py

pass=0; fail=0
# 日志不能写在输出目录里：harness 会先调用 HLSLivePump.reset()，那一步会清空整个目录
logs=$(mktemp -d)
for args in "300 30 1.0" "600 25 2.0" "45 45 3.0" "900 15 1.0" "120 12 1.5" "240 8 2.5"; do
  out=$(mktemp -d)
  tag=$(echo "$args" | tr ' ' '_')
  if "$BIN" "$out" $args > "$logs/$tag.log" 2>&1 && python3 Tools/validate_mp4.py "$out" > "$logs/$tag.val" 2>&1; then
    printf 'PASS  %-14s %s\n' "$args" "$(grep 切出 "$logs/$tag.log" | head -1)"
    grep -E '✅|❌' "$logs/$tag.log" || true
    pass=$((pass+1))
  else
    printf 'FAIL  %-14s\n' "$args"; tail -8 "$logs/$tag.log" "$logs/$tag.val" || true
    fail=$((fail+1))
  fi
  rm -rf "$out"
done
rm -rf "$logs"

# HLSLivePump 的清理逻辑
pumpdir=$(mktemp -d)
cat > "$pumpdir/main.swift" <<'EOF'
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let pump = HLSLivePump(directory: dir)
pump.reset()
pump.publishInitIfNeeded(Data([1, 2, 3]))
for i in 0..<12 {
  pump.publishSegment(index: UInt64(i), bytes: Data(repeating: 7, count: 64), playlist: "#EXTM3U\n")
}
pump.pruneSegments(keepFromIndexFrom: 8)
let items: [String] = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
let left = items.filter { $0.hasPrefix("fr-") }.count
print("prune 后剩 \(left) 个分片（期望 6：keepFrom=8 再留 2 片余量）")
if left != 6 { exit(1) }
EOF
swiftc -O Sources/Muxer/HLSLivePump.swift Sources/Support/Log.swift "$pumpdir/main.swift" -o "$pumpdir/pumptest"
"$pumpdir/pumptest" "$pumpdir/data" && pass=$((pass+1)) || fail=$((fail+1))
rm -rf "$pumpdir"

echo
echo "合计  通过 $pass  失败 $fail"
[ "$fail" -eq 0 ]

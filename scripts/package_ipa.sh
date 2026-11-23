#!/bin/bash
# 把已构建好的 .app 组装成 ipa（zip + Payload 目录结构）。
# Linux 和 macOS 通用 —— 云构建最后一步就调这个。
#
#   ./scripts/package_ipa.sh [Debug|Release] [DerivedData路径]
#
# 产物：build/MirrorCast.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-Release}
DERIVED=${2:-}

if [ -z "$DERIVED" ]; then
  for cand in build/DerivedData DerivedData ~/Library/Developer/Xcode/DerivedData; do
    [ -d "$cand" ] && DERIVED="$cand" && break
  done
fi
[ -n "$DERIVED" ] || { echo "!! 找不到 DerivedData，先跑 xcodebuild 或 scripts/build_ipa.sh"; exit 1; }

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -type d -name "MirrorCast.app" 2>/dev/null | head -1)
[ -n "$APP" ] || APP=$(find "$DERIVED" -maxdepth 4 -type d -name "MirrorCast.app" 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "!! 在 $DERIVED 里没找到 MirrorCast.app（配置=$CONFIG？真机 SDK？）"; exit 1; }

echo "› 来源: $APP"
rm -rf build/Payload
mkdir -p build/Payload
cp -R "$APP" build/Payload/

if [ -d "build/Payload/MirrorCast.app/PlugIns" ]; then
  echo "› 扩展: $(ls build/Payload/MirrorCast.app/PlugIns | tr '\n' ' ')"
else
  echo "!! 警告：没有 PlugIns，录屏广播扩展没进包 → 整机镜像会失效"
fi

# 有没有签名，这里如实说明：未签名的 ipa 只能交给 Sideloadly/AltStore 这类工具再签
if codesign --verify --verbose=2 "build/Payload/MirrorCast.app" >/dev/null 2>&1; then
  echo "› 包内已带签名校验通过"
  SIGNED=1
else
  echo "› 包内无有效签名：需要在自己电脑上用 Apple ID 重签（见 README「云端出包」一节）"
  SIGNED=0
fi

rm -f build/MirrorCast.ipa
( cd build && zip -qr MirrorCast.ipa Payload )

SIZE=$(du -h build/MirrorCast.ipa | cut -f1)
echo "✔ build/MirrorCast.ipa ($SIZE, signed=$SIGNED)"

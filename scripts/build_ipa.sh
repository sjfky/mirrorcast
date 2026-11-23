#!/bin/bash
# 在 macOS 上一条命令出 MirrorCast.ipa。
#
#   ./scripts/build_ipa.sh                 # 不签名：给 Sideloadly / AltStore 装（会重签）
#   TEAM=ABCDE1234 ./scripts/build_ipa.sh  # 用你的开发证书签名：可装到已注册设备，7 天有效
#
# 为什么不在 Linux 沙箱里做：IPA 必须有 iOS SDK + Apple 证书签名链，
# 二者都无法在别的平台上产生。这个脚本就是那台 Mac 上跑的东西。
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT=MirrorCast
SCHEME=MirrorCast
CONFIG=Release
OUT=build
DERIVED="$OUT/DerivedData"

[ "$(uname -s)" = "Darwin" ] || { echo "!! 必须在 macOS 上跑（需要 iOS SDK 与 codesign）"; exit 1; }

if ! command -v xcodegen >/dev/null; then
  echo "!! 缺 xcodegen：先执行  brew install xcodegen"
  exit 1
fi

echo "› 生成工程"
xcodegen generate

APP_TEAM_ARGS=()
if [ -n "${TEAM:-}" ]; then
  echo "› 使用 Team=$TEAM 签名"
  APP_TEAM_ARGS=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_ALLOWED=YES)
  xcodebuild -project "$PROJECT.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" "${APP_TEAM_ARGS[@]}" build
else
  echo "› 未提供 TEAM：产出未签名 .app（可被 Sideloadly/AltStore 重签，不能直接安装）"
  xcodebuild -project "$PROJECT.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
fi

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -type d -name "$PROJECT.app" | head -1)
[ -n "$APP" ] || { echo "!! 没找到产出的 $PROJECT.app，看上面的 xcodebuild 报错"; exit 1; }

echo "› 打包 Payload/$PROJECT.app"
rm -rf "$OUT/Payload"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"

# 录屏扩展必须躺在 .app/PlugIns 里，否则手机装上了也选不到广播
if [ ! -d "$OUT/Payload/$PROJECT.app/PlugIns" ]; then
  echo "!! 警告：没有 PlugIns 目录 → 广播扩展没被打进去，整机镜像会失效"
else
  echo "› 扩展: $(ls "$OUT/Payload/$PROJECT.app/PlugIns")"
fi

IPA="$OUT/$PROJECT.ipa"
rm -f "$IPA"
( cd "$OUT" && zip -qr "$PROJECT.ipa" Payload )

echo
if [ -n "${TEAM:-}" ]; then
  codesign --verify --deep --strict --verbose=2 "$OUT/Payload/$PROJECT.app" || echo "（签名校验有告警，见上）"
fi
echo "✔ $IPA  $(du -h "$IPA" | cut -f1)"
echo
echo "安装方式："
if [ -n "${TEAM:-}" ]; then
  echo "  · Apple Configurator / Xcode → Devices 直接拖进去（设备 UDID 需在该 Team 下）"
else
  echo "  · Sideloadly 或 AltStore：用它们装载这个 ipa 并用你自己的免费/付费账号重签"
  echo "  · 注意未签名的 ipa 直接装会报 'Untrusted Developer' 或直接失败，这是 iOS 的规则"
fi

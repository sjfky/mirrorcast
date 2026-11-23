# 需要在 macOS 上执行（本机是 Linux 沙箱，没有 iOS SDK）
XCODEPROJ = MirrorCast.xcodeproj
TEAM ?=

.PHONY: gen open build ipa clean team

gen:
	@command -v xcodegen >/dev/null || { echo "先执行: brew install xcodegen"; exit 1; }
	xcodegen generate

open: gen
	open $(XCODEPROJ)

# 出 ipa（默认未签名；TEAM=xxx 则顺带签名）
ipa:
	@command -v xcodegen >/dev/null || { echo "先执行: brew install xcodegen"; exit 1; }
	TEAM=$(TEAM) ./scripts/build_ipa.sh

# 带 Team ID 生成，省得每次在 Xcode 里手选
team:
	@test -n "$(TEAM)" || { echo "用法: make team TEAM=XXXXXXXXXX"; exit 1; }
	@sed -i '' 's/^    DEVELOPMENT_TEAM: "".*/    DEVELOPMENT_TEAM: "$(TEAM)"/' project.yml
	@echo "已写入 DEVELOPMENT_TEAM=$(TEAM)，接着跑 make gen"

build: gen
	xcodebuild -project $(XCODEPROJ) -scheme MirrorCast \
	  -sdk iphoneos -configuration Debug -destination 'generic/platform=iOS' \
	  CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf $(XCODEPROJ) build DerivedData

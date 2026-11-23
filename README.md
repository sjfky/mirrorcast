# MirrorCast

iPhone 画面 / 媒体 URL 推到局域网接收端（电视、盒子、车机浏览器）的 iOS 源码工程。
架构参考 [OpenXPlay](https://github.com/OpenXPlay)：**接收端不装任何 App**，用设备已有的入口显示。

## 先说清楚它不是什么

**这不是 CarPlay，也不可能做成 CarPlay。** 三点，缺一不可：

1. CarPlay 的第三方扩展只有 `CPMapTemplate` / `CPListTemplate` / `CPNowPlaying` 这类模板，**Apple 没有给任何"把视频/屏幕送上车机屏"的 API**，行车安全策略明确禁止。
2. CarPlay 连接的鉴权要 **MFi 认证**。OpenXPlay 之所以需要那台 Rust 中继（Android/Linux/UFI003），就是让**中继**去当 CarPlay 车机端；iPhone 侧永远是 CarPlay 的客户端，不存在"能接收 CarPlay 的 iOS App"。
3. DLNA 靠 SSDP + SOAP 传 URL，CarPlay 走的是另一套私有链路 + MFi 鉴权，两者不在一个协议层上。

所以本工程的定位是：**绕开 CarPlay 协议，把画面按 OpenXPlay 的合法输出路径送进车机** —— 车机浏览器直连。

## 三条输出路径

```
                     ┌── A  DLNA 点播推送 ── SetAVTransportURI(URL) ─────▶ 电视自己拉流（NAS/直链/m3u8）
iPhone 采集/片源 ────┼── B  DLNA 直播镜像 ── H.264+AAC → 每段一个 AVAssetWriter
                     │      → fMP4 拆包 → /live/stream.m3u8 ────────────▶ 支持 HLS 的 DMR（含声音）
                     └── C  网页镜像 ── HTTP multipart MJPEG ───────────▶ 车机自带浏览器（无声音）
```
B 与 C 是同一个采集源的两个编码分支；A 与它们互不影响。

| | A DLNA 点播 | B DLNA 直播镜像 | C 网页镜像 |
|---|---|---|---|
| 内容 | 一个 URL，接收端自己拉 | 手机屏幕（H.264/AAC） | 手机屏幕（JPEG） |
| 画质 | 无损（不转码） | 2.4 Mbps VBR | 有损 q0.48，长边 1152 |
| 延迟 | 取决于源起播 | ≈ 3–7 s（HLS 缓冲） | < 400 ms |
| 音频 | 跟随源 | **有** | 无 |
| 接收端 | 任意 DMR | 会放 HLS 的 DMR（Kodi/VLC/多数安卓盒子） | 任意浏览器 |

JPEG 多段流不在任何 DMR 的能力列表里，所以"镜像 + DLNA"必须转 H.264 —— 这就是路径 B 存在的原因；
而相当一部分电视自带的媒体播放器不吃 live HLS，所以路径 C 保留作**兜底**，两者同时输出、互不干扰。

## 关于"每段一个 AVAssetWriter"

直播切段最容易踩的坑是让一个 writer 一直写、然后去拆**正在增长**的 fMP4：写作过程中
`mdat` 的长度字段可能是"直到文件尾"的中间态，增量拆包要么读到半截，要么把没写完的段误判成完整段。
这里改成每段起一个新会话、`finish` 之后再拆：

1. 文件里所有 box 尺寸都是终值 → 拆包是纯确定性操作；
2. 新会话的第一个采样必是 IDR → 天然满足"分片必须以关键帧开头"，不用去请求强制关键帧；
3. `movieTimeOffset = 已发布总时长` 让相邻分片的 `tfdt` 接得上，播放列表里不需要 DISCONTINUITY；
4. 音频走同一个 writer，才有"镜像带声音"。

代价是每段重建一次编码器会话（几十毫秒），所以换段期间用有界缓冲把帧接住，
按到达顺序冲给 input（乱序 append 会让 AVAssetWriter 直接变 failed）。

## 已经验证到什么程度

**能在 Linux 上跑的部分我全跑了**，没有只靠读代码：Swift 6.4.3 工具链 + 一套自测。

| 组件 | 验证方式 | 结果 |
|---|---|---|
| `H264.parseSPS` | 用 Python 独立实现 SPS 编码器生成 `6742c028ed00a00b72`，Swift 侧解析 | 1280x720 / profile 66 / level 40 对齐 |
| fMP4 容器（Tools 里的自建复用器） | 自写 Python box 解析器逐字段核：mvhd 108B / tkhd 92B / mdhd 32B、stbl 表序与空表、avcC 自洽、trex 全 0 | 通过 |
| `trun.data_offset` | 校验"指向的字节 == mdat 载荷首字节"；`Σsample_size == mdat 长度 - 8` | 通过（这是手写 MP4 第一号错误源） |
| 分片时间轴 | 相邻分片 `tfdt[n+1] == tfdt[n] + Σdur[n]`，且每片首样本 `is_non_sync=0` | 通过 |
| `FragmentedMP4Splitter` | 把 init+10 片拼成流，按 4093 字节步长反复 `ingest`：切出字节与原片**逐字节相同**且幂等 | 通过 |
| `extractInitAndFragments` | 单会话文件（=路径 B 的真实形态）抽 init + 1 片 | 通过 |
| `HLSLivePump` 写序与 `pruneSegments` | 12 片→prune(keepFrom=8) 剩 6 片，窗口边界正确 | 通过 |
| `HLSWindow` | 6 组参数（帧数/GOP/段长）× TARGETDURATION≥最长片、MEDIA-SEQUENCE 与文件名一致 | 通过 |
| **UIKit/ReplayKit/AVFoundation 胶水** | 无 iOS SDK，编译不了 | **未验证，需 Mac 首轮编译** |
| **真机+真电视端到端** | 需要设备 | **未验证** |

一条命令跑完（6 组参数 × 容器校验 + 切片幂等 + 清理逻辑）：
```bash
./Tools/run_checks.sh
# 合计  通过 7  失败 0
```
只需要 `swiftc`，macOS 上有 Xcode 就自带，不需要 iOS SDK —— 这也是为什么这些组件能在
Linux 沙箱里真跑起来，而 UI/采集那层不行。

## 文件结构

```
project.yml                      XcodeGen 配置（App + 广播扩展两个 target）
scripts/build_ipa.sh             Mac 上一条命令出 ipa（TEAM=xxx 则顺带签名）
scripts/package_ipa.sh           只把编好的 .app 组装成 ipa（Linux 也能跑，CI 末尾调它）
.github/workflows/build-ipa.yml  GitHub Actions 云构建（免本机 Mac）
Info.plist                       App：本地网络权限 / ATS / App Group
Broadcast/Info.plist             扩展：NSExtensionPointIdentifier = replaykit.broadcast-upload-service
MirrorCast(.Broadcast).entitlements   com.apple.security.application-groups
Sources/
  Support/XML.swift              轻量 DOM + 转义（DIDL 双转义坑的根源）
  Support/Locking.swift          NSLock.guarding
  Support/Log.swift              NSSLog（App 与扩展共用一份）
  Discovery/SSDPDiscovery.swift  M-SEARCH，单播回包，不用组播 entitlement
  Discovery/DeviceDescriptionLoader.swift  取 description.xml，抽 AVTransport controlURL
  UPnP/SOAPClient.swift          POST + SOAPAction + UPnPError 码表
  UPnP/AVTransportProxy.swift    Play/Pause/Seek/GetPositionInfo + DIDL 生成 + 音量
  Cast/Models.swift              Renderer / DIDLItem / TransportState
  Cast/CastController.swift      总控、状态轮询、服务生命周期
  Muxer/HLSWindow.swift           滑动窗口 + m3u8 文本（三条路径共用一份实现）
  Muxer/FragmentedMP4Splitter.swift  fMP4 拆包：增长文件 ingest / 完整文件 extract
  Muxer/HLSLivePump.swift         分片与播放列表落盘（先写片再写列表）+ 旧片清理
  Capture/HLSSegmentWriter.swift  每段一个 AVAssetWriter 会话（路径 B 的心脏）
  Capture/AppGroupBridge.swift    扩展↔App 帧桥 + live/ 目录 + 开关
  Net/LiveStreamRoutes.swift      /live/stream.m3u8 · init.mp4 · fr-<n>.m4s（白名单 + Range）
  Net/WebServer.swift            FrameBus + HTTP/1.1 GET + multipart MJPEG
  Capture/AppGroupBridge.swift   扩展↔App 的帧文件桥（两个 target 共用）
  Capture/FrameEncoder.swift     CVPixelBuffer → 缩放 → JPEG
  Capture/ExtensionFramePoller.swift   App 侧轮询 frame.jpg
  Capture/ScreenCapturer.swift   App 内 RPScreenRecorder（只能拍本 App）
  Broadcast/SampleHandler.swift  整机录屏采集，只能编到扩展 target
  UI/ContentView.swift           三条路径的操作界面
Resources/web/index.html         车机浏览器里的接收页（无依赖，纯 HTML/JS）
Tools/
  MuxerCheck/*.swift             Linux 可编译的复用器 + 切片器测试台（不进 iOS target）
  gen_sps.py                     独立实现一遍 SPS 编码，用来交叉验证解析器
  validate_mp4.py                用 Python 解析 MP4，逐字段校验容器与播放列表
  run_checks.sh                  一把跑完上面所有自测
```
`Tools/` 里的 `FragmentedMP4Muxer.swift` 目前不参与打包：它是测试台的样本发生器，
同时也是"iOS 16 上不想依赖 AVAssetWriter 分片输出"时的备用实现（已通过同一套字节级校验）。

## 云端出包（手上一台 Mac 都没有，就走这条）

整条链路只用浏览器 + 一台能装软件的电脑，不需要你拥有 Mac。

### 第 1 段 · 云编译出 .ipa（约 5 分钟，全程网页操作）

1. 有 GitHub 账号就跳到第 3 步；没有就在 github.com 用邮箱注册一个（免费）。
2. **仓库设成 Public**。免费的 macOS 构建额度只对公开仓库开放，私有仓库几秒就把月度分钟数耗光。
   本工程里没有任何密钥、账号或私有接口，公开是安全的。
3. 右上角 **New repository** → 起名 `mirrorcast` → Public → **Create repository**。
4. 仓库页里 **uploading an existing file** → 上传文件。
   **关键**：先在电脑上把 zip 解压，然后把 `MirrorCast/` 里的**全部条目**（共 38 个文件，
   含 `.github`、`Scripts` 那几个目录）一起拖进上传区 —— `.github/workflows/` 必须落在
   **仓库根目录**，如果外面还套一层 `MirrorCast/`，Actions 不会认这条 workflow。
   上传完在文件列表里确认根目录能看到 `.github`。
5. 打开 **Actions** 标签 → 左边选「云端构建 MirrorCast.ipa」→ 右边 **Run workflow**
   → `team_id` **留空** → 绿色 Run workflow。
6. 几分钟后点进那次运行，最底下 **Artifacts** 里下载 `MirrorCast-unsigned-xxxx`，
   解压得到 `MirrorCast.ipa`。

到这里得到的 ipa 是**未签名**的，双击装不进手机——这不是构建失败，而是 Apple 的规则：
签名必须用你自己的 Apple 账号在现场完成，云端拿不到你的账号也就不能替你签。

### 第 2 段 · 用你自己的免费 Apple ID 签进去（需要一台 Windows 电脑）

1. 装 **Sideloadly**（sideloadly.io，Win/Mac 都有）。
2. 手机数据线连电脑，手机上点**信任此电脑**。
3. Sideloadly 里把 `MirrorCast.ipa` 拖进左上角方框 → 填你的 **Apple ID**（不需要付费开发者账号，
   普通 Apple ID 就行）→ **Start** → 在手机上输一次验证码。
4. 手机上：**设置 → 通用 → VPN与设备管理** → 点你那串 App ID → **信任** → 打开 App。

免费账号签出来的限制要先知道，免得白折腾：

| 限制 | 具体表现 | 处理 |
|---|---|---|
| 7 天过期 | 到点图标变灰打不开 | 重连电脑再签一次；或用 **SideStore**（手机上自刷，装完 7 天内联网即可，不用每次都插电脑） |
| 同时最多 3 个自签 App | 第 4 个会挤掉前面的 | 腾位置 |
| 需要一次性注册设备 UDID | 首次签署时 Sideloadly 会带上你这台设备的 UDID | 换手机要重签 |
| 付费开发者账号（$99/年） | 签名 1 年有效、无 3 个限制、可装任意设备 | 要长期用车机投屏才值得 |

### 第 3 段 · 想让云端直接出**已签名**包（可选）

填 `team_id` 之前，必须先把证书带进 CI（**先跑通未签名那条，再考虑这个**）：`.p12` + `provisioning profile` 作为
**Repository secrets** 存好，再把 workflow 里的 `CODE_SIGN_STYLE=Automatic` 换成
显式导入钥匙串的流程。**不要把 Apple ID 密码明文写进 workflow 或提交到仓库。**
第一次跑建议就留空走未签名 + Sideloadly，最省事。

---

## 本地构建（手上有 Mac 的话）

iOS SDK 与 Apple 证书签名链只能在 macOS 上产生，所以**打包 ipa 这一步必须在 Mac 上做**——
这不是工具选择问题，而是 iOS 的安装机制决定的：设备的 amfid 只认 Apple 信任链签出来的包。

```bash
brew install xcodegen
cd MirrorCast
open MirrorCast.xcodeproj            # 先在里面选 Team、把 App Group 改成自己的
# 或者直接用脚本出 ipa：
./scripts/build_ipa.sh               # 未签名 ipa（交给 Sideloadly / AltStore 重签）
TEAM=ABCDE1234 ./scripts/build_ipa.sh  # 用你的开发证书签好，可直接装注册设备
```

然后必改三处，少一处就装不上或跑不通：

1. **Signing & Capabilities**：两个 target 都选你的 Team。免费 Apple ID 也可以侧载，7 天过期。
2. **App Group**：把 `project.yml`、两份 `.entitlements`、`Sources/Capture/AppGroupBridge.swift` 里的
   `group.com.example.mirrorcast` 全部换成你自己的（后缀随意，但四处必须一致）。
3. **Broadcast Bundle ID**：`com.example.mirrorcast.broadcast` 必须是 App ID 的子前缀，
   同时 `Sources/UI/ContentView.swift` 里 `preferredExtension` 要填同一个值，
   否则「开始广播」的列表里找不到你的扩展。

真机运行，首次会弹**本地网络**权限 —— 必须允许，拒绝后表现为「搜不到任何设备」，
要去 设置 → 隐私与安全性 → 本地网络 里手动打开。

## 用法

三条路径共用同一个采集源，按接收端能力挑。

### A · 把视频直接推给电视（点播，画质无损）

填一个接收端能访问的 URL → 选设备 → 推送。接收端自己拉流，手机不参与传输。

- 内网文件：`http://192.168.1.20:32400/…`（NAS / Plex / 自建 http）
- 公网直链：`.mp4` 兼容性最好，`.m3u8` 一般也能放
- 带 token 的直链会过期，电视卡住多半是 716 URI no longer valid，重新推一次
- DRM 内容（Netflix / Disney+ 这类）注定失败，也不该做

### B · 镜像走 DLNA（带声音）

1. 先打开界面上的**同时输出 DLNA 直播**。这个开关写进 App Group，
   扩展是在 `broadcastStarted` 里才读它 —— **必须先开开关，再开始录屏**，反了就一直 0 片。
2. 点**开始系统录屏** → 系统弹「屏幕广播」→ 选 MirrorCast → 开始广播。
3. 等"分片"计数 > 0，选设备 → 把这个直播流推给所选设备。
4. 延迟约 3–7 秒（HLS 缓冲决定的，不是 bug）。接收端不吃 live HLS 就黑屏，
   那是 DMR 的能力边界，退回 C 或换 Kodi / VLC 当接收端。

### C · 车机浏览器直连（最通用，无声音）

1. 手机和车机连**同一个路由器**（这点最要紧，见排查表）。
2. 启动服务，界面出现 `http://192.168.x.x:8090/`。
3. 车机浏览器打开这个地址。
4. 不开录屏广播时这里只能拍到本 App 自己的画面 ——
   Apple 限制 `RPScreenRecorder.startCapture` 只覆盖调用方内容，整机画面只能由扩展拿到。

## 排查表

| 现象 | 真实原因 | 处理 |
|---|---|---|
| 一台设备都搜不到 | 2.4G/5G 被路由器拆成两段，或开了 AP 隔离 | 让手机和电视接同一段；关 AP 隔离 |
| 搜不到特定电视 | 电视的 DLNA/媒体共享/多屏互动开关默认关闭 | 电视设置里打开 |
| 搜到但一推就失败 | 本地网络权限被拒（监听和访问局域网都归它管） | 设置 → 隐私与安全性 → 本地网络 |
| 推送 708 Bad Metadata | DIDL 转义层数错了，或缺 `<res>` | 见 `AVTransportProxy.metadata(for:)` 注释 |
| 推送 715 / 711 | 电视硬解不支持这个编码（常见 HEVC / AV1 / EAC3） | 换 H.264 + AAC 源 |
| 推送 718 Illegal URL | URL 为空或设备拒绝该地址 | 检查 scheme；检查接收端能否访问手机 IP |
| 直播推上去黑屏 | 该 DMR 不吃 live HLS | 走路径 C，或换 Kodi / VLC 当接收端 |
| 直播一直 0 片 | 开关是在开始录屏**之后**才打开的 | 停广播 → 开开关 → 重开广播 |
| 直播有画面没声音 | 广播没拿到系统音频（源本身静音） | 换个有声的源再试 |
| 浏览器打开是空白 | 录屏广播没开，`/mjpeg` 一直没帧 | 完成 B 节第 2 步 |
| 镜像只有本 App 界面 | 只开了 App 内采集 | 必须走系统录屏广播 |
| 镜像卡成幻灯片 | 车机浏览器 JPEG 解码太弱 | 把 `encoder.maxEdge` 降到 854、quality 0.4 |
| 退出 App 就断 | 服务与 HLS 供给都在 App 进程里 | `UIBackgroundModes=audio` 可缓解；上商店需删 |
| `make team` 报 sed 错 | 在 Linux 上跑了 Makefile（BSD sed 写法） | 那一步只在 macOS 做 |

## 还没做完的（按性价比排序）

1. **横竖屏**：见 `Capture/ScreenCapturer.swift` 的 `TODO(旋转)`。扩展侧没有可靠的界面方向
   来源，只能按像素宽高比反推；`HLSSegmentWriter.reconfigure` 已经留了"尺寸变化即收段"的入口，
   接上方向判定就能补齐。
2. **已签名云构建**：现在 CI 出的是未签名包，还要过一次 Sideloadly。把证书与描述文件放进
   Repository secrets、workflow 里显式导入钥匙串，就能出**装完即开**的 ipa。
   注意：Apple ID 密码不要明文写进 workflow，也不要提交进仓库。
3. **首轮真机编译**：`Capture/HLSSegmentWriter.swift` 与 `Broadcast/SampleHandler.swift`
   是唯一没被本机编译器碰过的两个文件（纯 AVFoundation / ReplayKit 签名）。
   CI 第一次跑若报错，把 log 原文发回来即可，其余组件已在 Linux 上跑过字节级自测。
4. **接收端能力探测**：现在"这台电视吃不吃 live HLS"靠人肉判断。可以先试推、再轮询
   `GetTransportInfo` 看落点是 `PLAYING` 还是 `NO_MEDIA_PRESENT`，自动在 B / C 之间选路。
5. **音频码率与直播画质档位**：`HLSSegmentWriter.Config` 里 2.4 Mbps / 96 kbps 是写死的，
   应按网络与设备档位调。
6. **HTTPS 接收页**：车机浏览器若有 mixed-content 或强制升级 https 的行为会连不上，
   需要自签证书 + 在车机侧信任（OpenXPlay 就是这么做的）。

## 许可与出处

- 本工程代码为**原创实现**，参考的是 OpenXPlay 的**架构分层**（接收端零安装、中继/输出解耦、
  浏览器与 DLNA 并列多条输出路径），没有复制它的任何一行代码。
- OpenXPlay 各仓库：`OpenXPlay-Relay`、`OpenXPlay-Stream`、`OpenXPlay-Flasher` 是 **AGPL-3.0**，
  `OpenXPlay-DiPlay` 是 **GPL-3.0**，而主仓库 `OpenXPlay`（Vue 网页接收端）**没有 LICENSE 文件** ——
  没有许可证就意味着默认保留所有权利，**不能复制它的源码**。如果你要把这套东西并回它的生态，
  自己的分发也要按 AGPL 开源。
- 主仓库里那份 `Resources/web/index.html` 是本工程的独立实现，与 OpenXPlay 的 Vue 接收端无关，
  只用了 multipart MJPEG 这个公开机制。
- 涉及 CarPlay 的部分：本工程完全不实现 CarPlay 协议，因此不需要 MFi，也不涉及任何认证数据。
- DLNA / UPnP / HLS / fMP4 全部是公开规范（UDA 2.1、AVTransport:1、RFC 8216、ISO/IEC 14496-12），
  实现自写，没有引用任何第三方 UPnP 库。

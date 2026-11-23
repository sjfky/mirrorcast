import SwiftUI
import ReplayKit

@main
struct MirrorCastApp: App {
    @StateObject private var cast = CastController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cast)
                .preferredColorScheme(.dark)
                .onAppear { cast.bootstrap() }
                .onDisappear { cast.teardown() }
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var cast: CastController
    @State private var urlText = ""
    @State private var kind: DIDLItem.Kind = .video
    @State private var showURLSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MirrorPanel()
                    DLANAPanel(urlText: $urlText, kind: $kind)
                }
                .padding(16)
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.08))
            .navigationTitle("MirrorCast")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showURLSheet = true } label: { Image(systemName: "qrcode.viewfinder") }
                }
            }
            .alert("出错了", isPresented: Binding(
                get: { cast.lastError != nil },
                set: { if !$0 { cast.lastError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(cast.lastError ?? "")
            }
            .sheet(isPresented: $showURLSheet) { AddressSheet() }
        }
    }
}

// MARK: - 路径 C：网页镜像（+ 路径 B 的 DLNA 直播开关）

private struct MirrorPanel: View {
    @EnvironmentObject var cast: CastController

    var body: some View {
        Panel(title: "镜像 · 车机浏览器直连 (C)，可选同时走 DLNA (B)",
              subtitle: "手机开着 HTTP 服务，车机浏览器打开下面地址即可看到画面") {
            if let url = cast.receiverURL {
                Text(url)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.lime)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(cast.mirrorActive ? "取不到 Wi-Fi 地址" : "服务未启动")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            LiveFrameView()
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if cast.frameCount == 0 {
                        Text("等待画面\n点下面「开始系统录屏」")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }

            HStack(spacing: 10) {
                Button(cast.mirrorActive ? "停止服务" : "启动服务") {
                    if cast.mirrorActive {
                        cast.stopMirrorServer()
                    } else {
                        cast.startMirrorServer()
                    }
                }
                .buttonStyle(.bordered)

                BroadcastPickerButton()
                Spacer()
                Text("\(cast.frameCount) 帧")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LiveMirrorBlock()

            Text("没帧 = 录屏广播没开。iOS 不允许第三方代码自己启动整机录屏，必须用户在这个面板上点一次开始。")
                .font(.caption)
                .foregroundStyle(.orange.opacity(0.9))
        }
    }
}

/// RPSystemBroadcastPickerView：系统提供的入口，按钮外观和文案都归系统，代码无法伪造
private struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 140, height: 44))
        view.preferredExtension = "com.example.mirrorcast.broadcast"
        view.showsMicrophoneButton = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// 直接吃 FrameBus，不走网络回环，省一次 JPEG 解码往返
private struct LiveFrameView: View {
    @EnvironmentObject var cast: CastController
    @State private var image: UIImage?
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .onReceive(timer) { _ in
            guard let frame = cast.frames.current else { return }
            // 帧号没变就不重建 UIImage
            if frame.seq == lastSeq { return }
            lastSeq = frame.seq
            image = UIImage(data: frame.jpeg)
        }
    }

    @State private var lastSeq: UInt64 = 0
}

/// 把实时画面再走一遍 DLNA：需要扩展配合，改开关后必须重开广播
private struct LiveMirrorBlock: View {
    @EnvironmentObject var cast: CastController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $cast.liveMirrorEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同时输出 DLNA 直播").font(.subheadline.weight(.medium))
                    Text("手机把屏幕编码成 H.264+AAC 的 HLS，推给电视/盒子这类 DLNA 接收端。含声音。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(Color.lime)
            .onChange(of: cast.liveMirrorEnabled) { _ in cast.applyLiveMirrorFlag() }

            if let url = cast.livePlaylistURL {
                HStack {
                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer()
                    Text("\(cast.liveSegments) 片")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button {
                    cast.pushLiveMirror()
                } label: {
                    Text(cast.liveSegments > 0 ? "把这个直播流推给所选设备" : "仍然推送（等扩展出片）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 路径 A：DLNA

private struct DLANAPanel: View {
    @EnvironmentObject var cast: CastController
    @Binding var urlText: String
    @Binding var kind: DIDLItem.Kind

    var body: some View {
        Panel(title: "DLNA 推送 · 让设备自己拉流",
              subtitle: "只传一个 URL，画质不经二次压缩；要求电视/盒子开了 DLNA 接收") {
            HStack {
                Button {
                    cast.startDiscovery()
                } label: {
                    Label("重新搜索", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                Spacer()
                if cast.isDiscovering { ProgressView().controlSize(.small) }
            }

            if cast.renderers.isEmpty {
                EmptyRendererHint()
                    .padding(.vertical, 6)
            } else {
                ForEach(cast.renderers) { renderer in
                    RendererRow(renderer: renderer, isSelected: renderer.id == cast.selectedID)
                        .onTapGesture { cast.select(renderer) }
                }
            }

            Divider().overlay(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 8) {
                TextField("http://…/movie.mp4  或  …/live.m3u8", text: $urlText)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Picker("类型", selection: $kind) {
                    ForEach(DIDLItem.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Button {
                    cast.pushURLString(urlText, kind: kind)
                } label: {
                    HStack {
                        if cast.isPushing { ProgressView().controlSize(.small) }
                        Text(cast.isPushing ? "推送中…" : "推送到所选设备")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.lime)
                .foregroundStyle(.black)
                .disabled(cast.selected == nil || cast.isPushing || urlText.isEmpty)
            }

            if cast.currentItem != nil {
                TransportPanel()
            }
        }
    }
}

private struct RendererRow: View {
    let renderer: Renderer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.lime : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(renderer.name).font(.body.weight(.medium))
                Text(renderer.modelInfo ?? renderer.hostLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !renderer.isPlayable {
                Text("无 AVTransport").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct EmptyRendererHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("没发现可推送设备").font(.footnote.weight(.semibold))
            Text("排查顺序：① 手机和电视同一个路由器、同网段（2.4G/5G 被拆成两段就废了）② 路由器没开 AP 隔离 ③ 电视设置里 DLNA/媒体共享/多屏互动 开关打开 ④ 系统设置 → 隐私 → 本地网络，本 App 允许")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TransportPanel: View {
    @EnvironmentObject var cast: CastController
    @State private var scrub: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cast.currentItem?.title ?? "").font(.footnote).lineLimit(1)
            HStack(spacing: 6) {
                Text(time(scrub))
                Slider(value: $scrub, in: 0...max(1, cast.position.duration), onEditingChanged: { editing in
                    if !editing { cast.seek(scrub) }
                })
                Text(time(cast.position.duration))
            }
            .font(.system(.caption2, design: .monospaced))
            .onAppear { scrub = cast.position.relTime }
            .onChange(of: cast.position.relTime) { value in
                if cast.transport == .playing { scrub = value }
            }

            HStack(spacing: 14) {
                Button { cast.pause() } label: { Image(systemName: "pause.circle") }
                Button { cast.resume() } label: { Image(systemName: "play.circle.fill") }
                Button { cast.stop() } label: { Image(systemName: "stop.circle") }
                Spacer()
                Image(systemName: "speaker.wave.2")
                Slider(value: Binding(get: { Double(cast.volume) },
                                      set: { cast.volume = Int($0) }), in: 0...100) {
                    Text("音量")
                } onEditingChanged: { editing in
                    if editing { cast.applyVolume() }
                }
                .frame(width: 110)
                Text("\(cast.volume)").font(.system(.caption2, design: .monospaced)).frame(width: 26)
            }
            .font(.title3)
            .buttonStyle(.plain)

            Text("状态 \(cast.transport.rawValue) · 目标 \(cast.selected?.hostLabel ?? "-")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func time(_ t: TimeInterval) -> String { AVTransportProxy.clock(t) }
}

// MARK: - 通用

private struct Panel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct AddressSheet: View {
    @EnvironmentObject var cast: CastController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("接收端地址") {
                    Text(cast.receiverURL ?? "服务未启动")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("怎么开 DLNA 接收") {
                    Text("""
                    电视/盒子侧：
                    · 安卓电视或盒子装 VLC / Kodi，Kodi 的接收与解码兼容性最好
                    · 索尼/三星/海信等自带"投屏/DLNA/媒体共享"开关，默认常关，要手动打开
                    · 车机如果没有 DLNA，就只用上面的网页镜像地址，浏览器打开即可
                    """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("推什么 URL") {
                    Text("""
                    URL 必须是接收端能访问到的地址。
                    · 内网文件：NAS / Plex / 自己起的 http 服务，推 http://192.168.x.x/…
                    · 公网直链：mp4、m3u8 都行；m3u8 兼容性最好
                    · 带 token 的直链会过期，电视卡住就是过期了，重新推一次
                    """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("说明")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

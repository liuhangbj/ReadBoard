import CoreImage.CIFilterBuiltins
import ReadBoardContract
import ReadBoardUI
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct ReadBoardSourceTypeDescriptor: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String

    static let all: [Self] = [
        .init(id: "article", title: "文章 / RSS", subtitle: "常规 RSS 文章订阅", icon: "doc.text"),
        .init(id: "podcast", title: "播客", subtitle: "音频节目与转录", icon: "waveform"),
        .init(id: "youtube", title: "YouTube", subtitle: "视频与字幕", icon: "play.rectangle"),
        .init(id: "bilibili", title: "BiliBili", subtitle: "UP 主视频与字幕", icon: "play.tv"),
        .init(id: "wechat", title: "微信公众号", subtitle: "公众号订阅与正文提取", icon: "message.fill"),
    ]
}

public struct ReadBoardPlatformSettingsPane: View {
    private let sourceCatalog: any SourceCatalogGateway
    private let authentication: any AuthenticationGateway
    private let configuration: any ConfigurationGateway
    private let permissions: ReadBoardFeaturePermissions

    @State private var flags: [String: Bool] = [:]
    @State private var sourceCounts: [String: Int] = [:]
    @State private var authentications: [PlatformAuthenticationStatus] = []
    @State private var challenge: PlatformAuthenticationChallenge?
    @State private var errorMessage: String?
    @State private var signOutStatus: PlatformAuthenticationStatus?

    public init(
        sourceCatalog: any SourceCatalogGateway,
        authentication: any AuthenticationGateway,
        configuration: any ConfigurationGateway,
        permissions: ReadBoardFeaturePermissions
    ) {
        self.sourceCatalog = sourceCatalog
        self.authentication = authentication
        self.configuration = configuration
        self.permissions = permissions
    }

    public var body: some View {
        Form {
            Section {
                ForEach(ReadBoardSourceTypeDescriptor.all) { type in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 12) {
                            Image(systemName: type.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(ReadBoardDesign.C.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(type.title).font(.system(size: 13, weight: .semibold))
                                    if let count = sourceCounts[type.id], count > 0 {
                                        ReadBoardBadge(text: "\(count) 个源", color: ReadBoardDesign.C.text3)
                                    }
                                }
                                Text(type.subtitle).font(.caption).foregroundStyle(ReadBoardDesign.C.text2)
                            }
                            Spacer()
                            if permissions.allows(.manageSources, capability: .sourceManagement) {
                                Toggle("", isOn: typeBinding(type.id)).labelsHidden()
                            }
                        }
                        if let auth = authenticationStatus(type.id), auth.phase != .notRequired {
                            authenticationRow(auth).padding(.leading, 36)
                        }
                    }
                    .padding(.vertical, 5)
                }
            } header: {
                Text("多平台订阅")
            } footer: {
                Text("关闭类型后不会删除已有内容，但该类型的抓取与新建订阅会暂停。具体订阅源请在“订阅管理”中维护。")
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .sheet(isPresented: Binding(
            get: { challenge != nil },
            set: { if !$0 { challenge = nil } })) {
                if let challenge {
                    ReadBoardPlatformAuthenticationSheet(
                        challenge: challenge,
                        authentication: authentication,
                        onComplete: {
                            self.challenge = nil
                            await reload()
                        },
                        onCancel: { self.challenge = nil })
                }
            }
        .alert("退出平台登录？", isPresented: Binding(
            get: { signOutStatus != nil },
            set: { if !$0 { signOutStatus = nil } })) {
                Button("取消", role: .cancel) { signOutStatus = nil }
                Button("退出登录", role: .destructive) {
                    guard let value = signOutStatus else { return }
                    signOutStatus = nil
                    Task {
                        do {
                            try await authentication.signOut(platformID: value.platformID)
                            await reload()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        .alert("平台操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "请稍后重试")
            }
    }

    private func typeBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { flags[id] ?? true },
            set: { value in
                flags[id] = value
                let gateway = configuration
                Task { await gateway.setSourceTypeFlag(id, enabled: value) }
            })
    }

    private func authenticationStatus(_ sourceType: String) -> PlatformAuthenticationStatus? {
        let platform = sourceType == "bilibili" ? "bilibili"
            : sourceType == "wechat" ? "wechat" : nil
        return platform.flatMap { id in authentications.first(where: { $0.platformID == id }) }
    }

    private func authenticationRow(_ status: PlatformAuthenticationStatus) -> some View {
        HStack(spacing: 8) {
            Circle().fill(authenticationColor(status.phase)).frame(width: 7, height: 7)
            Text(status.accountName ?? status.message ?? authenticationTitle(status.phase))
                .font(.caption).foregroundStyle(ReadBoardDesign.C.text2).lineLimit(1)
            Spacer()
            ReadBoardBadge(text: authenticationTitle(status.phase),
                           color: authenticationColor(status.phase))
            if permissions.allows(.manageAuthentication, capability: .authentication) {
                if status.phase == .authenticated {
                    Button("退出") { signOutStatus = status }
                        .buttonStyle(ReadBoardQuietButtonStyle())
                } else {
                    Button("重新登录") { beginAuthentication(status.platformID) }
                        .buttonStyle(ReadBoardSecondaryButtonStyle())
                }
            }
        }
    }

    @MainActor
    private func reload() async {
        async let config = configuration.snapshot()
        async let auth = authentication.statuses()
        flags = await config.sourceTypeFlags
        if let loadedCatalog = try? await sourceCatalog.snapshot() {
            sourceCounts = Dictionary(grouping: loadedCatalog.sources, by: \.sourceType)
                .mapValues(\.count)
        } else {
            sourceCounts = [:]
        }
        authentications = await auth
    }

    private func beginAuthentication(_ platformID: String) {
        Task {
            do {
                challenge = try await authentication.beginAuthentication(platformID: platformID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func authenticationTitle(_ phase: PlatformAuthenticationPhase) -> String {
        switch phase {
        case .notRequired: "无需登录"
        case .authenticated: "已登录"
        case .waitingForScan: "等待扫码"
        case .waitingForConfirmation: "等待确认"
        case .repairing: "正在修复"
        case .needsAttention: "需要处理"
        case .signedOut: "未登录"
        case .expired: "已过期"
        }
    }

    private func authenticationColor(_ phase: PlatformAuthenticationPhase) -> Color {
        switch phase {
        case .notRequired, .authenticated: ReadBoardDesign.C.scoreHigh
        case .waitingForScan, .waitingForConfirmation, .repairing: ReadBoardDesign.C.scoreMid
        case .needsAttention, .signedOut, .expired: ReadBoardDesign.C.scoreLow
        }
    }
}

private struct ReadBoardPlatformAuthenticationSheet: View {
    let challenge: PlatformAuthenticationChallenge
    let authentication: any AuthenticationGateway
    let onComplete: @MainActor () async -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        VStack(spacing: ReadBoardDesign.Space.lg) {
            Text("平台登录").font(.system(size: 18, weight: .semibold, design: .serif))
            if let image = qrImage(challenge.qrPayload) {
                image.resizable().interpolation(.none).scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(10).background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
            }
            Text("使用对应平台 App 扫描二维码并确认登录")
                .font(.caption).foregroundStyle(ReadBoardDesign.C.text2)
            Button("取消", action: onCancel)
                .buttonStyle(ReadBoardSecondaryButtonStyle())
        }
        .padding(ReadBoardDesign.Space.xl)
        .frame(minWidth: 360, minHeight: 420)
        .background(ReadBoardDesign.C.bg)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                do {
                    let result = try await authentication.pollAuthentication(
                        platformID: challenge.platformID,
                        challengeID: challenge.challengeID)
                    if result.completed { await onComplete(); return }
                } catch { return }
            }
        }
    }

    private func qrImage(_ value: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(macOS)
        return Image(nsImage: NSImage(cgImage: image, size: NSSize(width: 220, height: 220)))
        #else
        return Image(uiImage: UIImage(cgImage: image))
        #endif
    }
}

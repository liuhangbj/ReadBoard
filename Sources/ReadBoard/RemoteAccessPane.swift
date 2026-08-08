import AppKit
import CoreImage.CIFilterBuiltins
import ReadBoardContract
import SwiftUI

public struct RemoteAccessPane: View {
    private let remoteAccess: any RemoteAccessGateway
    @State private var snapshot = RemoteAccessSnapshot(
        configuration: RemoteAccessConfiguration(), state: .stopped)
    @State private var editing = RemoteAccessConfiguration()
    @State private var portText = "7331"
    @State private var dirty = false
    @State private var busy = false
    @State private var challenge: RemotePairingChallenge?
    @State private var pairingPreset: RemoteAccessPreset = .reader
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var message = ""
    @State private var messageIsError = false

    public init(remoteAccess: any RemoteAccessGateway) {
        self.remoteAccess = remoteAccess
    }

    public var body: some View {
        Form {
            Section("服务状态") {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.system(size: 13, weight: .semibold))
                        if let error = snapshot.lastError, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(Color.rbScoreLow)
                        }
                    }
                    Spacer()
                    Button("刷新") { Task { await refresh(forceConfiguration: false) } }
                        .controlSize(.small)
                }

                if snapshot.serviceURLs.isEmpty {
                    Text("服务启动后会在这里显示可连接地址。")
                        .font(.caption).foregroundStyle(Color.rbText3)
                } else {
                    ForEach(snapshot.serviceURLs, id: \.self) { url in
                        LabeledContent("连接地址") {
                            HStack(spacing: 6) {
                                Text(url).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                    message = "已复制连接地址"; messageIsError = false
                                } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.quiet).help("复制")
                            }
                        }
                    }
                }
            }

            Section("监听设置") {
                Toggle("启用远程访问服务", isOn: configBinding(\.enabled))
                    .tint(Color.rbAccent)
                Toggle("允许局域网设备连接", isOn: configBinding(\.allowLAN))
                    .tint(Color.rbAccent)
                    .disabled(!editing.enabled)
                HStack {
                    Text("端口")
                    Spacer()
                    TextField("7331", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .disabled(!editing.enabled)
                        .onChange(of: portText) { _, _ in dirty = true }
                }
                HStack {
                    Text(editing.allowLAN
                         ? "将监听 0.0.0.0，局域网设备可访问。"
                         : "仅监听 127.0.0.1，其他设备无法访问。")
                        .font(.caption).foregroundStyle(Color.rbText3)
                    Spacer()
                    Button(busy ? "应用中…" : "应用") { applyConfiguration() }
                        .buttonStyle(.primaryCapsule).controlSize(.small)
                        .disabled(!dirty || busy || validatedPort == nil)
                }
            }

            Section {
                LabeledContent("密码登录") {
                    Text(snapshot.passwordConfigured ? "已启用" : "尚未设置")
                        .foregroundStyle(snapshot.passwordConfigured
                            ? Color.rbScoreHigh : Color.rbScoreMid)
                }
                SecureField(snapshot.passwordConfigured ? "输入新密码" : "设置访问密码",
                            text: $newPassword)
                    .textFieldStyle(.roundedBorder)
                SecureField("再次输入", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("至少 10 个字符。修改密码不会自动撤销已登录设备。")
                        .font(.caption).foregroundStyle(Color.rbText3)
                    Spacer()
                    Button(snapshot.passwordConfigured ? "更新密码" : "启用密码登录") {
                        setAccessPassword()
                    }
                    .buttonStyle(.primaryCapsule).controlSize(.small)
                    .disabled(busy || newPassword.count < 10 || newPassword != confirmPassword)
                }
                if let name = snapshot.bonjourServiceName {
                    LabeledContent("局域网发现名称", value: name)
                }
                if let fingerprint = snapshot.certificateFingerprint {
                    LabeledContent("TLS 证书指纹") {
                        Text(formattedFingerprint(fingerprint))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("访问密码与 HTTPS")
            } footer: {
                Text("ReadBoard Go 首次连接时固定此证书指纹；登录后只保存可单独撤销的设备令牌。")
                    .font(.caption).foregroundStyle(Color.rbText3)
            }

            Section("设备配对") {
                if let challenge, challenge.expiresAt > Date().timeIntervalSince1970 {
                    HStack(alignment: .top, spacing: 18) {
                        if let image = qrImage(challenge.qrPayload) {
                            Image(nsImage: image)
                                .resizable().interpolation(.none).scaledToFit()
                                .frame(width: 170, height: 170)
                                .padding(8).background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("使用 ReadBoard Go 扫描二维码")
                                .font(.system(size: 13, weight: .semibold))
                            Text("或手动输入配对码")
                                .font(.caption).foregroundStyle(Color.rbText3)
                            Text(challenge.code)
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                            Text("5 分钟内有效，仅可使用一次。")
                                .font(.caption).foregroundStyle(Color.rbScoreMid)
                            Button("取消配对") { cancelPairing() }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("访问权限", selection: $pairingPreset) {
                            Text("仅阅读").tag(RemoteAccessPreset.reader)
                            Text("完整控制").tag(RemoteAccessPreset.fullControl)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("添加阅读设备")
                                .font(.system(size: 13, weight: .semibold))
                            Text("每台设备获得独立令牌，可以单独撤销。")
                                .font(.caption).foregroundStyle(Color.rbText3)
                        }
                        Spacer()
                        Button("生成配对二维码") { beginPairing() }
                            .buttonStyle(.primaryCapsule).controlSize(.small)
                            .disabled(snapshot.state != .running || busy)
                        }
                    }
                }
            }

            Section {
                if snapshot.devices.isEmpty {
                    Text("尚未配对任何设备")
                        .font(.caption).foregroundStyle(Color.rbText3)
                } else {
                    ForEach(snapshot.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "laptopcomputer.and.iphone")
                                .foregroundStyle(Color.rbAccent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.system(size: 13, weight: .medium))
                                Text(deviceDetail(device))
                                    .font(.caption2).foregroundStyle(Color.rbText3)
                            }
                            Spacer()
                            Button("撤销", role: .destructive) {
                                Task {
                                    do {
                                        try await remoteAccess.revokeDevice(id: device.id)
                                        message = "已撤销 \(device.name) 的访问权限"
                                        messageIsError = false
                                        await refresh(forceConfiguration: false)
                                    } catch {
                                        message = "撤销失败：\(error.localizedDescription)"
                                        messageIsError = true
                                    }
                                }
                            }
                            .buttonStyle(.quiet).controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("已配对设备")
            } footer: {
                Text("设备令牌只在登录或配对成功时返回一次；服务端仅保存 SHA-256 哈希。")
                    .font(.caption).foregroundStyle(Color.rbText3)
            }

            if !message.isEmpty {
                Section {
                    Text(message).font(.caption)
                        .foregroundStyle(messageIsError ? Color.rbScoreLow : Color.rbScoreHigh)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refresh(forceConfiguration: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let challenge, challenge.expiresAt <= Date().timeIntervalSince1970 {
                    self.challenge = nil
                }
                await refresh(forceConfiguration: false)
            }
        }
        .onDisappear {
            if let challenge { Task { await remoteAccess.cancelPairing(challengeID: challenge.id) } }
        }
    }

    private var validatedPort: UInt16? {
        guard let value = Int(portText), (1024...65535).contains(value) else { return nil }
        return UInt16(value)
    }

    private func configBinding(_ path: WritableKeyPath<RemoteAccessConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { editing[keyPath: path] }, set: {
            editing[keyPath: path] = $0; dirty = true
        })
    }

    private func applyConfiguration() {
        guard let port = validatedPort else { return }
        editing.port = port
        busy = true; message = ""
        Task {
            await remoteAccess.updateConfiguration(editing)
            try? await Task.sleep(for: .milliseconds(500))
            dirty = false; busy = false
            await refresh(forceConfiguration: true)
            messageIsError = snapshot.state == .failed
            message = snapshot.state == .failed ? (snapshot.lastError ?? "服务启动失败") : "远程访问设置已应用"
            challenge = nil
        }
    }

    private func beginPairing() {
        busy = true; message = ""
        Task {
            do {
                challenge = try await remoteAccess.beginPairing(scopes: pairingPreset.scopes)
                messageIsError = false
            } catch {
                message = error.localizedDescription; messageIsError = true
            }
            busy = false
        }
    }

    private func setAccessPassword() {
        guard newPassword == confirmPassword else { return }
        busy = true; message = ""
        Task {
            do {
                try await remoteAccess.setAccessPassword(newPassword)
                newPassword = ""; confirmPassword = ""
                message = "远程访问密码已更新"
                messageIsError = false
                await refresh(forceConfiguration: false)
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            busy = false
        }
    }

    private func cancelPairing() {
        guard let challenge else { return }
        self.challenge = nil
        Task { await remoteAccess.cancelPairing(challengeID: challenge.id) }
    }

    @MainActor
    private func refresh(forceConfiguration: Bool) async {
        snapshot = await remoteAccess.snapshot()
        if forceConfiguration || !dirty {
            editing = snapshot.configuration
            portText = String(snapshot.configuration.port)
        }
    }

    private var statusColor: Color {
        switch snapshot.state {
        case .running: .rbScoreHigh
        case .starting: .rbScoreMid
        case .failed: .rbScoreLow
        case .stopped: .rbText3
        }
    }

    private var statusTitle: String {
        switch snapshot.state {
        case .running: "远程访问服务运行正常"
        case .starting: "远程访问服务正在启动"
        case .failed: "远程访问服务启动失败"
        case .stopped: "远程访问服务已关闭"
        }
    }

    private func deviceDetail(_ device: PairedRemoteDevice) -> String {
        let created = Date(timeIntervalSince1970: device.createdAt)
            .formatted(date: .abbreviated, time: .shortened)
        let permission = device.scopes == RemoteAccessScope.reader ? "仅阅读" : "完整控制"
        guard let lastSeenAt = device.lastSeenAt else {
            return "\(permission) · 配对于 \(created) · 尚未连接"
        }
        let lastSeen = Date(timeIntervalSince1970: lastSeenAt)
            .formatted(date: .abbreviated, time: .shortened)
        return "\(permission) · 配对于 \(created) · 最近连接 \(lastSeen)"
    }

    private func formattedFingerprint(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 2).compactMap { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(2, value.distance(from: start,
                                                                         to: value.endIndex)))
            return String(value[start..<end]).uppercased()
        }.joined(separator: ":")
    }

    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
    }
}

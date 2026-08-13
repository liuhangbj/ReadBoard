import ReadBoardContract
import ReadBoardUI
import SwiftUI

/// Core 与 Go 共用的通用设置。自动刷新和代理都通过 Contract gateway 权威回读，
/// 页面不接触 SourceStore、UserDefaults 或 HTTP 客户端。
public struct ReadBoardGeneralSettingsPane: View {
    private let sourceManagement: any SourceManagementGateway
    private let configuration: any ConfigurationGateway

    @State private var autoSyncEnabled = true
    @State private var intervalMinutes = 60
    @State private var proxyEnabled = false
    @State private var proxyURL = ""
    @State private var isLoading = true
    @State private var statusMessage: String?

    public init(
        sourceManagement: any SourceManagementGateway,
        configuration: any ConfigurationGateway
    ) {
        self.sourceManagement = sourceManagement
        self.configuration = configuration
    }

    public var body: some View {
        Form {
            Section {
                ReadBoardSettingsToggleRow("自动周期抓取", isOn: $autoSyncEnabled)
                    .onChange(of: autoSyncEnabled) { _, value in
                        saveSync(enabled: value, minutes: intervalMinutes)
                    }
                if autoSyncEnabled {
                    ReadBoardSettingsPickerRow("抓取间隔", selection: $intervalMinutes) {
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                            Text("1 小时").tag(60)
                            Text("2 小时").tag(120)
                            Text("4 小时").tag(240)
                            Text("8 小时").tag(480)
                            Text("12 小时").tag(720)
                            Text("24 小时").tag(1440)
                    }
                    .onChange(of: intervalMinutes) { _, value in
                        saveSync(enabled: autoSyncEnabled, minutes: value)
                    }
                }
            } header: {
                ReadBoardSettingsSectionTitle("订阅源自动刷新")
            }

            Section {
                ReadBoardSettingsToggleRow("使用 HTTP 代理", isOn: $proxyEnabled)
                    .onChange(of: proxyEnabled) { _, value in
                        if !value { proxyURL = "" }
                        saveProxy()
                    }
                if proxyEnabled {
                    ReadBoardSettingsInputRow("代理地址") {
                        HStack(spacing: 8) {
                            TextField("http://127.0.0.1:7890", text: $proxyURL)
                                .readBoardSettingsInput()
                                .onSubmit(saveProxy)
                            Button("保存", action: saveProxy)
                                .buttonStyle(ReadBoardSecondaryButtonStyle())
                                .readBoardSettingsButton(.inline)
                        }
                    }
                }
                Text("代理只作用于 ReadBoard 服务端的抓取和外部接口请求。")
                    .readBoardTextRole(.detail)
                    .foregroundStyle(ReadBoardDesign.C.text3)
            } header: {
                ReadBoardSettingsSectionTitle("网络代理")
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "checkmark.circle")
                        .readBoardTextRole(.detail)
                        .foregroundStyle(ReadBoardDesign.C.scoreHigh)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isLoading)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        async let sync = try? sourceManagement.syncSettings()
        async let config = try? configuration.snapshot()
        let loadedSync = await sync
        let loadedConfig = await config
        if let loadedSync {
            autoSyncEnabled = loadedSync.enabled
            intervalMinutes = loadedSync.intervalMinutes
        }
        if let loadedConfig {
            proxyURL = loadedConfig.proxyURL
            proxyEnabled = !loadedConfig.proxyURL.isEmpty
        }
        isLoading = false
    }

    private func saveSync(enabled: Bool, minutes: Int) {
        guard !isLoading else { return }
        Task {
            do {
                try await sourceManagement.updateSyncSettings(
                    SourceSyncSettings(enabled: enabled, intervalMinutes: minutes))
                statusMessage = "自动刷新设置已保存"
            } catch {
                statusMessage = error.localizedDescription
                await load()
            }
        }
    }

    private func saveProxy() {
        guard !isLoading else { return }
        let value = proxyEnabled
            ? proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        Task {
            await configuration.setProxyURL(value)
            statusMessage = value.isEmpty ? "代理已关闭" : "代理设置已保存"
        }
    }
}

public struct ReadBoardReaderSettingsPane: View {
    public init() {}

    public var body: some View {
        ReadBoardReadingSettingsView(presentation: .settingsPane)
    }
}

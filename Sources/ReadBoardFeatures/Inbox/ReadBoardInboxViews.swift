import ReadBoardContract
import ReadBoardUI
import SwiftUI

public struct ReadBoardInboxImportSheet: View {
    private let inbox: any InboxGateway
    private let initialURL: String
    private let onImported: (InboxImportResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var kind = InboxContentKind.automatic
    @State private var isImporting = false
    @State private var errorMessage: String?

    public init(
        inbox: any InboxGateway,
        initialURL: String = "",
        onImported: @escaping (InboxImportResult) -> Void = { _ in }
    ) {
        self.inbox = inbox
        self.initialURL = initialURL
        self.onImported = onImported
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("添加到收件箱").readBoardTextRole(.pageTitle)
                Text("链接会自动识别为文章、播客或视频。")
                    .readBoardTextRole(.detail)
                    .foregroundStyle(.secondary)
            }
            ReadBoardSettingsInputRow("链接") {
                TextField("https://", text: $url)
                    .readBoardSettingsInput()
            }
            ReadBoardSettingsPickerRow("类型", selection: $kind) {
                Text("自动识别").tag(InboxContentKind.automatic)
                Text("文章").tag(InboxContentKind.article)
                Text("播客").tag(InboxContentKind.podcast)
                Text("视频").tag(InboxContentKind.video)
            }
            if let errorMessage {
                Text(errorMessage).readBoardTextRole(.detail).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button(isImporting ? "正在添加…" : "添加") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { if url.isEmpty { url = initialURL } }
    }

    private func submit() {
        isImporting = true
        errorMessage = nil
        Task {
            do {
                let result = try await inbox.importURL(
                    InboxImportRequest(url: url, suggestedKind: kind))
                await MainActor.run {
                    onImported(result)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }
}

public struct ReadBoardInboxSettingsPane: View {
    private let inbox: any InboxGateway
    @State private var configuration = InboxConfiguration()
    @State private var loaded = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    public init(inbox: any InboxGateway) {
        self.inbox = inbox
    }

    public var body: some View {
        Form {
            Section {
                targetRows("文章", targets: articleTargets, media: false)
                targetRows("播客", targets: podcastTargets, media: true)
                targetRows("视频", targets: videoTargets, media: true)
            } header: {
                ReadBoardSettingsSectionTitle("新链接的处理目标")
            } footer: {
                Text("目标会在入库时固化到每条内容。修改默认值不会自动重跑历史内容。")
                    .readBoardTextRole(.detail)
            }
            Section {
                ReadBoardSettingsToggleRow("新内容保持未读", isOn: $configuration.markNewItemsUnread)
                ReadBoardSettingsToggleRow("允许自动导出规则", isOn: $configuration.allowAutomaticExport)
                ReadBoardSettingsActionRow {
                    Text("历史内容")
                        .readBoardTextRole(.itemTitle)
                    Spacer()
                    Button("应用当前目标") { retarget() }
                }
                if let statusMessage {
                    Text(statusMessage).readBoardTextRole(.detail).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).readBoardTextRole(.detail).foregroundStyle(.red)
                }
            } header: {
                ReadBoardSettingsSectionTitle("收件行为")
            } footer: {
                Text("默认不让收件箱内容自动导出；仍可在阅读器中手动导出单篇内容。")
                    .readBoardTextRole(.detail)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .onChange(of: configuration) { _, value in
            guard loaded else { return }
            Task { try? await inbox.updateConfiguration(value) }
        }
    }

    @ViewBuilder
    private func targetRows(
        _ title: String,
        targets: Binding<InboxProcessingTargets>,
        media: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).readBoardTextRole(.itemTitle)
            ReadBoardSettingsToggleRow("自动获取正文或字幕", isOn: targets.fulltext)
            ReadBoardSettingsToggleRow("AI评分", isOn: targets.score)
            ReadBoardSettingsToggleRow("AI摘要", isOn: targets.summary)
            ReadBoardSettingsToggleRow("AI翻译", isOn: targets.translate)
            if media {
                ReadBoardSettingsToggleRow("AI转录", isOn: targets.transcribe)
            }
        }
        .padding(.vertical, 4)
    }

    private var articleTargets: Binding<InboxProcessingTargets> {
        Binding(get: { configuration.articleTargets }, set: { configuration.articleTargets = $0 })
    }
    private var podcastTargets: Binding<InboxProcessingTargets> {
        Binding(get: { configuration.podcastTargets }, set: { configuration.podcastTargets = $0 })
    }
    private var videoTargets: Binding<InboxProcessingTargets> {
        Binding(get: { configuration.videoTargets }, set: { configuration.videoTargets = $0 })
    }

    private func load() async {
        do {
            configuration = try await inbox.configuration()
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func retarget() {
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let result = try await inbox.applyCurrentTargetsToExistingItems()
                await MainActor.run { statusMessage = result.message }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

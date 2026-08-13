import Foundation
import ReadBoardContract
import ReadBoardUI
import SwiftUI

public struct ReadBoardMaintenanceSettingsPane: View {
    private let maintenance: any MaintenanceGateway

    @State private var snapshot = MaintenanceSnapshot(
        policy: CleanupPolicy(), usage: StorageUsage(), backups: [], trash: [])
    @State private var policy = CleanupPolicy()
    @State private var isLoading = true
    @State private var busyAction: String?
    @State private var message: String?
    @State private var policySaveTask: Task<Void, Never>?
    @State private var backupToRestore: BackupRecord?
    @State private var trashToDelete: TrashBatchRecord?
    @State private var confirmClearTrash = false

    public init(maintenance: any MaintenanceGateway) {
        self.maintenance = maintenance
    }

    public var body: some View {
        Form {
            storageSection
            policySection
            backupSection
            trashSection
            if let message {
                Section { Text(message).readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.text2) }
            }
        }
        .formStyle(.grouped)
        .disabled(isLoading)
        .task { await reload() }
        .onChange(of: policy) { _, _ in schedulePolicySave() }
        .alert("恢复数据库备份？", isPresented: Binding(
            get: { backupToRestore != nil },
            set: { if !$0 { backupToRestore = nil } })) {
                Button("取消", role: .cancel) { backupToRestore = nil }
                Button("恢复", role: .destructive) {
                    guard let backup = backupToRestore else { return }
                    backupToRestore = nil
                    Task { await restoreBackup(backup) }
                }
            } message: {
                Text("当前数据库会先保存为安全备份，然后替换为所选版本。恢复完成后请重新启动 ReadBoard。")
            }
        .alert("永久删除这批回收站内容？", isPresented: Binding(
            get: { trashToDelete != nil },
            set: { if !$0 { trashToDelete = nil } })) {
                Button("取消", role: .cancel) { trashToDelete = nil }
                Button("永久删除", role: .destructive) {
                    guard let item = trashToDelete else { return }
                    trashToDelete = nil
                    Task { await deleteTrash(item) }
                }
            }
        .alert("清空回收站？", isPresented: $confirmClearTrash) {
            Button("取消", role: .cancel) {}
            Button("永久清空", role: .destructive) { Task { await clearTrash() } }
        } message: {
            Text("回收站中的所有内容备份都会永久删除，无法恢复。")
        }
    }

    private var storageSection: some View {
        Section {
            ReadBoardSettingsValueRow("数据库", value: bytes(snapshot.usage.databaseBytes))
            ReadBoardSettingsValueRow(
                "数据库备份",
                value: "\(bytes(snapshot.usage.backupBytes)) · \(snapshot.usage.backupCount) 份")
            ReadBoardSettingsValueRow(
                "临时文件",
                value: "\(bytes(snapshot.usage.temporaryBytes)) · \(snapshot.usage.temporaryCount) 项")
            ReadBoardSettingsValueRow("回收站", value: bytes(snapshot.usage.trashBytes))
            ReadBoardSettingsValueRow(
                "可清理原始 HTML",
                value: "\(snapshot.usage.cleanableHTMLCount) 条")
            HStack {
                Spacer()
                Button {
                    Task { await runCleanup() }
                } label: {
                    if busyAction == "cleanup" { ProgressView().controlSize(.small) }
                    else { Label("立即清理", systemImage: "sparkles") }
                }
                .buttonStyle(ReadBoardSecondaryButtonStyle())
                .readBoardSettingsButton(.inline)
                .disabled(busyAction != nil)
            }
        } header: {
            ReadBoardSettingsSectionTitle("当前占用")
        }
    }

    private var policySection: some View {
        Section {
            ReadBoardSettingsToggleRow("删除长期已读内容", isOn: $policy.deleteReadEnabled)
            if policy.deleteReadEnabled {
                ReadBoardSettingsStepperRow(
                    "已读内容保留",
                    value: $policy.deleteReadAfterDays,
                    range: 7...365,
                    step: 7,
                    displayValue: "\(policy.deleteReadAfterDays) 天")
            }
            ReadBoardSettingsToggleRow("清理已提取内容的原始 HTML", isOn: $policy.cleanHTML)
            if policy.cleanHTML {
                ReadBoardSettingsStepperRow(
                    "原始 HTML 保留",
                    value: $policy.cleanHTMLAfterDays,
                    range: 1...90,
                    displayValue: "\(policy.cleanHTMLAfterDays) 天")
            }
            ReadBoardSettingsToggleRow("限制数据库备份数量", isOn: $policy.backupRetentionEnabled)
            if policy.backupRetentionEnabled {
                ReadBoardSettingsStepperRow(
                    "数据库备份保留",
                    value: $policy.backupKeepCount,
                    range: 1...30,
                    displayValue: "\(policy.backupKeepCount) 份")
            }
        } header: {
            ReadBoardSettingsSectionTitle("清理策略")
        }
    }

    private var backupSection: some View {
        Section {
            HStack {
                Text(snapshot.lastBackupAt.map { "最近备份：\($0)" } ?? "尚无自动备份记录")
                    .readBoardTextRole(.detail)
                    .foregroundStyle(ReadBoardDesign.C.text3)
                Spacer()
                Button {
                    Task { await createBackup() }
                } label: {
                    if busyAction == "backup" { ProgressView().controlSize(.small) }
                    else { Label("创建备份", systemImage: "externaldrive.badge.plus") }
                }
                .buttonStyle(ReadBoardSecondaryButtonStyle())
                .readBoardSettingsButton(.inline)
                .disabled(busyAction != nil)
            }
            if let error = snapshot.lastBackupError, !error.isEmpty {
                Text(error).readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.scoreLow)
            }
            ForEach(snapshot.backups) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.displayName).readBoardTextRole(.itemTitle)
                        Text("\(backup.date.formatted(date: .abbreviated, time: .shortened)) · \(bytes(backup.sizeBytes))")
                            .readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.text3)
                    }
                    Spacer()
                    Button("恢复") { backupToRestore = backup }
                        .buttonStyle(ReadBoardSecondaryButtonStyle())
                        .readBoardSettingsButton(.inline)
                        .disabled(busyAction != nil)
                }
            }
        } header: {
            ReadBoardSettingsSectionTitle("数据库备份 / 恢复")
        }
    }

    private var trashSection: some View {
        Section {
            if snapshot.trash.isEmpty {
                Text("回收站为空").foregroundStyle(ReadBoardDesign.C.text3)
            } else {
                ForEach(snapshot.trash) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.date).readBoardTextRole(.itemTitle)
                            Text("\(item.itemCount) 条 · \(bytes(item.sizeBytes))")
                                .readBoardTextRole(.detail).foregroundStyle(ReadBoardDesign.C.text3)
                        }
                        Spacer()
                        Button("恢复") { Task { await restoreTrash(item) } }
                            .buttonStyle(ReadBoardSecondaryButtonStyle())
                            .readBoardSettingsButton(.inline)
                        Button(role: .destructive) { trashToDelete = item } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(ReadBoardDestructiveButtonStyle())
                        .readBoardSettingsButton(.icon)
                    }
                }
                HStack {
                    Spacer()
                    Button("清空回收站", role: .destructive) { confirmClearTrash = true }
                        .buttonStyle(ReadBoardDestructiveButtonStyle())
                        .readBoardSettingsButton(.inline)
                        .disabled(busyAction != nil)
                }
            }
        } header: {
            ReadBoardSettingsSectionTitle("回收站（删除内容的可恢复备份）")
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        if let loaded = try? await maintenance.snapshot() {
            snapshot = loaded
            policy = loaded.policy
        }
        isLoading = false
    }

    private func schedulePolicySave() {
        guard !isLoading else { return }
        policySaveTask?.cancel()
        policySaveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await maintenance.updatePolicy(policy)
            message = "清理策略已保存"
        }
    }

    private func runCleanup() async {
        busyAction = "cleanup"
        message = await maintenance.runCleanup()
        busyAction = nil
        await reload()
    }

    private func createBackup() async {
        busyAction = "backup"
        snapshot = await maintenance.createBackup()
        message = "数据库备份已创建"
        busyAction = nil
    }

    private func restoreBackup(_ backup: BackupRecord) async {
        busyAction = "restore"
        do {
            try await maintenance.restoreBackup(id: backup.id)
            message = "数据库备份已恢复，请重新启动 ReadBoard"
        } catch {
            message = error.localizedDescription
        }
        busyAction = nil
        await reload()
    }

    private func restoreTrash(_ item: TrashBatchRecord) async {
        busyAction = "trash"
        let result = await maintenance.restoreTrash(id: item.id)
        message = "已恢复 \(result.restored) 条，跳过 \(result.skipped) 条"
        busyAction = nil
        await reload()
    }

    private func deleteTrash(_ item: TrashBatchRecord) async {
        busyAction = "trash"
        await maintenance.deleteTrash(id: item.id)
        message = "回收站批次已永久删除"
        busyAction = nil
        await reload()
    }

    private func clearTrash() async {
        busyAction = "trash"
        await maintenance.clearTrash()
        message = "回收站已清空"
        busyAction = nil
        await reload()
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

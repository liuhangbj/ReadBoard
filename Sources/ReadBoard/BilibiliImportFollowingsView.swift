import SwiftUI

/// B站登录成功后导入已关注 UP 主的弹窗
/// 流程：拉取关注列表 → 用户勾选 → 选历史回溯范围 → 批量 addSource
struct BilibiliImportFollowingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SourceStore

    @State private var followings: [(mid: String, uname: String)] = []
    @State private var selectedMids: Set<String> = []
    @State private var historyScope: HistoryScope = .recent30d
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入已关注 UP 主")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.rbText)

            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在拉取关注列表...")
                        .font(.caption)
                        .foregroundStyle(Color.rbText2)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.rbScoreMid)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.rbText2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else {
                // 历史回溯范围选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("历史回溯范围")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.rbText3)
                        .tracking(RB.Track.section)
                    Picker("", selection: $historyScope) {
                        ForEach(HistoryScope.allCases, id: \.self) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.rbAccent)
                    .labelsHidden()
                }

                // 关注列表
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("选择要导入的 UP 主（已选 \(selectedMids.count)/\(followings.count)）")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.rbText3)
                            .tracking(RB.Track.section)
                        Spacer()
                        Button(selectedMids.count == followings.count ? "取消全选" : "全选") {
                            if selectedMids.count == followings.count {
                                selectedMids.removeAll()
                            } else {
                                selectedMids = Set(followings.map { $0.mid })
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.rbAccent)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(followings, id: \.mid) { item in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(
                                        get: { selectedMids.contains(item.mid) },
                                        set: { isOn in
                                            if isOn { selectedMids.insert(item.mid) }
                                            else { selectedMids.remove(item.mid) }
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .tint(Color.rbAccent)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.uname)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.rbText)
                                        Text("UID: \(item.mid)")
                                            .font(.caption2)
                                            .foregroundStyle(Color.rbText3)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(selectedMids.contains(item.mid) ? Color.rbAccent.opacity(0.08) : Color.clear)
                                .cornerRadius(6)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .background(Color.rbSurface)
                    .cornerRadius(8)
                }
            }

            // 底部按钮
            HStack {
                Button("跳过") {
                    dismiss()
                }
                .buttonStyle(.quiet)

                Spacer()

                Button(isImporting ? "导入中..." : "导入 \(selectedMids.count) 个") {
                    importSelected()
                }
                .buttonStyle(.primaryCapsule)
                .disabled(selectedMids.isEmpty || isImporting || isLoading)
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .task {
            await loadFollowings()
        }
    }

    private func loadFollowings() async {
        guard let sessdata = BilibiliAuth.sessdata,
              let uid = BilibiliAuth.uid else {
            errorMessage = "未登录或登录态失效"
            isLoading = false
            return
        }
        do {
            followings = try await BilibiliAuth.fetchFollowings(sessdata: sessdata, uid: uid)
            isLoading = false
        } catch {
            errorMessage = "拉取关注列表失败：\(error.localizedDescription)"
            isLoading = false
        }
    }

    private func importSelected() {
        isImporting = true
        Task {
            var successCount = 0
            var failCount = 0
            for mid in selectedMids {
                guard let item = followings.first(where: { $0.mid == mid }) else { continue }
                let identifier = "https://space.bilibili.com/\(mid)"
                if let _ = await store.addSource(
                    stype: "bilibili",
                    name: item.uname,
                    identifier: identifier,
                    folderId: nil,
                    pipeline: PipelinePolicy(),
                    fetchMode: nil
                ) {
                    successCount += 1
                } else {
                    failCount += 1
                }
            }
            await MainActor.run {
                isImporting = false
                if failCount == 0 {
                    dismiss()
                } else {
                    errorMessage = "导入完成：成功 \(successCount) 个，失败 \(failCount) 个（可能已存在）"
                }
            }
        }
    }
}

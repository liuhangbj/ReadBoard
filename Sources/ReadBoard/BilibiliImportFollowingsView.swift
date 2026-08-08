import SwiftUI
import ReadBoardContract

/// B站登录成功后导入已关注 UP 主的弹窗
/// 流程：拉取关注列表 → 用户勾选 → 选历史回溯范围 → 批量 addSource
struct BilibiliImportFollowingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let onboarding: any SourceOnboardingGateway

    @State private var followings: [PlatformSubscriptionCandidate] = []
    @State private var selectedMids: Set<String> = []
    @State private var historyScope: SourceHistoryScope = .recent30Days
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var isImporting = false

    init(onboarding: any SourceOnboardingGateway) {
        self.onboarding = onboarding
    }

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
                        ForEach(SourceHistoryScope.allCases, id: \.self) { scope in
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
                        Text("选择要导入的 UP 主（已选 \(selectedMids.count)/\(followings.filter { !$0.alreadySubscribed }.count)）")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.rbText3)
                            .tracking(RB.Track.section)
                        Spacer()
                        let availableIDs = Set(followings.filter { !$0.alreadySubscribed }.map(\.id))
                        Button(selectedMids == availableIDs ? "取消全选" : "全选") {
                            if selectedMids == availableIDs {
                                selectedMids.removeAll()
                            } else {
                                selectedMids = availableIDs
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.rbAccent)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(followings) { item in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(
                                        get: { selectedMids.contains(item.id) },
                                        set: { isOn in
                                            if isOn { selectedMids.insert(item.id) }
                                            else { selectedMids.remove(item.id) }
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .tint(Color.rbAccent)
                                    .disabled(item.alreadySubscribed)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.rbText)
                                        Text("UID: \(item.id)")
                                            .font(.caption2)
                                            .foregroundStyle(Color.rbText3)
                                        if item.alreadySubscribed {
                                            Text("已订阅")
                                                .font(.caption2)
                                                .foregroundStyle(Color.rbScoreMid)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(selectedMids.contains(item.id) ? Color.rbAccent.opacity(0.08) : Color.clear)
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
        do {
            followings = try await onboarding.platformSubscriptions(platform: "bilibili")
            selectedMids = Set(followings.filter { !$0.alreadySubscribed }.map(\.id))
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
                guard let item = followings.first(where: { $0.id == mid }) else { continue }
                if (try? await onboarding.create(request: SourceCreationRequest(
                    identifier: item.identifier,
                    name: item.name,
                    sourceType: "bilibili",
                    fetchMode: .bilibiliSubtitle,
                    historyScope: historyScope,
                    refreshAfterCreation: false))) != nil {
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

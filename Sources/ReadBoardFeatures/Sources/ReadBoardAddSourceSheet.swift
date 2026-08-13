import ReadBoardContract
import ReadBoardUI
import SwiftUI

public struct ReadBoardAddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var name = ""
    @State private var selectedType = "article"
    @State private var selectedFolderID: Int64?
    @State private var selectedFetchMode = SourceFetchMode.automatic
    @State private var historyScope = SourceHistoryScope.recent30Days
    @State private var policy = SourcePolicySnapshot()
    @State private var refreshAfterCreation = true
    @State private var supportedTypes: [SourceTypeDescriptor] = []
    @State private var discovery: SourceDiscoveryResult?
    @State private var isDiscovering = false
    @State private var localError: String?

    private let model: ReadBoardSourcesFeatureModel

    public init(model: ReadBoardSourcesFeatureModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加订阅源")
                        .readBoardInterfaceFont(size: 18, weight: .semibold)
                    Text("先检测地址，再确认名称、分组和处理策略")
                        .readBoardInterfaceFont(size: 11)
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ReadBoardQuietButtonStyle())
            }
            .padding(ReadBoardDesign.Space.xl)

            ReadBoardHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: ReadBoardDesign.Space.xl) {
                    fieldSection("订阅地址") {
                        HStack(spacing: ReadBoardDesign.Space.sm) {
                            TextField("RSS、播客、YouTube、Bilibili 或公众号文章地址", text: $identifier)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: identifier) { _, _ in discovery = nil }
                            Button { Task { await discover() } } label: {
                                if isDiscovering {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("检测", systemImage: "sparkle.magnifyingglass")
                                }
                            }
                            .buttonStyle(ReadBoardSecondaryButtonStyle())
                            .disabled(identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isDiscovering)
                        }

                        if let discovery {
                            HStack(spacing: 7) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ReadBoardDesign.C.scoreHigh)
                                Text("已识别为 \(typeName(discovery.sourceType))")
                                Text("·")
                                Text(discovery.fetchModeDisplayName)
                                if discovery.previewItemCount > 0 {
                                    Text("· 预览 \(discovery.previewItemCount) 条")
                                }
                            }
                            .readBoardInterfaceFont(size: 11)
                            .foregroundStyle(ReadBoardDesign.C.text2)
                        }
                    }

                    fieldSection("基本信息") {
                        LabeledContent("名称") {
                            TextField("订阅源名称", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 280)
                        }
                        LabeledContent("类型") {
                            Picker("类型", selection: $selectedType) {
                                ForEach(typeOptions) { type in
                                    Text(type.displayName).tag(type.id)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 180)
                        }
                        LabeledContent("文件夹") {
                            Picker("文件夹", selection: $selectedFolderID) {
                                Text("未分组").tag(Optional<Int64>.none)
                                ForEach(model.snapshot?.folders ?? []) { folder in
                                    Text(folder.name).tag(Optional(folder.id))
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 180)
                        }
                        LabeledContent("全文模式") {
                            Picker("全文模式", selection: $selectedFetchMode) {
                                ForEach(SourceFetchMode.allCases, id: \.rawValue) { mode in
                                    Text(fetchModeName(mode)).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 180)
                        }
                    }

                    fieldSection("自动处理") {
                        Toggle("AI 评分", isOn: policyBinding(\.autoScore))
                        Toggle("AI 摘要", isOn: policyBinding(\.autoSummarize))
                        Toggle("AI 翻译", isOn: policyBinding(\.autoTranslate))
                        Toggle("AI 转录", isOn: policyBinding(\.autoTranscribe))
                            .disabled(!isTranscribableType)
                    }

                    fieldSection("首次导入") {
                        Toggle("添加后立即刷新", isOn: $refreshAfterCreation)
                        if isMediaType {
                            Picker("历史范围", selection: $historyScope) {
                                Text("最近 30 天").tag(SourceHistoryScope.recent30Days)
                                Text("最近一年").tag(SourceHistoryScope.recentYear)
                                Text("全部历史").tag(SourceHistoryScope.all)
                            }
                        }
                    }

                    if let localError {
                        Label(localError, systemImage: "exclamationmark.triangle.fill")
                            .readBoardInterfaceFont(size: 11)
                            .foregroundStyle(ReadBoardDesign.C.scoreLow)
                    }
                }
                .padding(ReadBoardDesign.Space.xl)
            }

            ReadBoardHairline()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(ReadBoardSecondaryButtonStyle())
                Button("添加订阅源") { Task { await create() } }
                    .buttonStyle(ReadBoardPrimaryButtonStyle())
                    .disabled(discovery == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isWorking("source:create"))
            }
            .padding(ReadBoardDesign.Space.md)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 660)
        .background(ReadBoardDesign.C.bg)
        .task { supportedTypes = await model.supportedSourceTypes() }
    }

    private func fieldSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.md) {
            ReadBoardSectionLabel(text: title)
            content()
        }
        .padding(ReadBoardDesign.Space.md)
        .background(ReadBoardDesign.C.surface.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
    }

    private var typeOptions: [SourceTypeDescriptor] {
        if !supportedTypes.isEmpty { return supportedTypes }
        return [
            SourceTypeDescriptor(id: "article", displayName: "文章 / RSS"),
            SourceTypeDescriptor(id: "podcast", displayName: "播客"),
            SourceTypeDescriptor(id: "youtube", displayName: "YouTube"),
            SourceTypeDescriptor(id: "bilibili", displayName: "Bilibili"),
            SourceTypeDescriptor(id: "wechat", displayName: "微信公众号"),
        ]
    }

    private var isMediaType: Bool {
        ["podcast", "youtube", "bilibili", "video"].contains(selectedType.lowercased())
    }

    private var isTranscribableType: Bool { isMediaType }

    private func discover() async {
        isDiscovering = true
        localError = nil
        defer { isDiscovering = false }
        do {
            let result = try await model.discover(
                identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                suggestedType: selectedType)
            discovery = result
            identifier = result.canonicalIdentifier
            selectedType = result.sourceType
            selectedFetchMode = result.fetchMode
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = result.suggestedName
            }
        } catch is CancellationError {
            return
        } catch {
            localError = error.localizedDescription
        }
    }

    private func create() async {
        guard let discovery else { return }
        let request = SourceCreationRequest(
            identifier: discovery.canonicalIdentifier,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceType: selectedType,
            folderID: selectedFolderID,
            policy: policy,
            fetchMode: selectedFetchMode,
            historyScope: isMediaType ? historyScope : nil,
            refreshAfterCreation: refreshAfterCreation)
        if await model.createSource(request) { dismiss() }
    }

    private func policyBinding(_ keyPath: WritableKeyPath<SourcePolicySnapshot, Bool>) -> Binding<Bool> {
        Binding(
            get: { policy[keyPath: keyPath] },
            set: { policy[keyPath: keyPath] = $0 })
    }

    private func typeName(_ id: String) -> String {
        typeOptions.first(where: { $0.id == id })?.displayName ?? id
    }

    private func fetchModeName(_ mode: SourceFetchMode) -> String {
        switch mode {
        case .automatic: "自动检测"
        case .feedFull: "Feed 全文"
        case .defuddle: "网页正文"
        case .youtubeSubtitle: "YouTube 字幕"
        case .bilibiliSubtitle: "Bilibili 字幕"
        case .externalFulltext: "外部全文"
        case .summary: "摘要"
        }
    }
}

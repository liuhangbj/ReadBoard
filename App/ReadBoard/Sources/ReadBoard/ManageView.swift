import SwiftUI

// MARK: - 管理面板
// 统一承载：统计概览 / 源健康 / 失败重试 / 过滤规则

public struct ManageView: View {
    @State private var tab = 0
    @EnvironmentObject private var appTab: AppTab

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                // 返回阅读（左栏底部导航切过来的入口）
                Button { appTab.selection = 0 } label: {
                    Label("阅读", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("返回阅读")
                .padding(.leading, 12)
                Spacer()
            }
            .padding(.top, 8)

            Picker("", selection: $tab) {
                Text("统计").tag(0)
                Text("源健康").tag(1)
                Text("失败重试").tag(2)
                Text("过滤规则").tag(4)
            }
            .pickerStyle(.segmented)
            .padding()

            Group {
                switch tab {
                case 0: StatsPane()
                case 1: SourceHealthPane()
                case 2: FailedJobPane()
                default: FilterRulePane()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

// MARK: 统计概览

public struct StatsPane: View {
    @State private var s = StatsOverview()
    @State private var jobTypes: [(jtype: String, ok: Int, failed: Int)] = []
    @State private var topSources: [(name: String, count: Int)] = []

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 概览卡片
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statCard("订阅源", "\(s.enabledSources)/\(s.totalSources)", "dot.radiowaves.left.and.right", .blue)
                    statCard("内容总数", "\(s.totalContent)", "doc.text", .primary)
                    statCard("未读", "\(s.unreadCount)", "circlebadge.fill", .orange)
                    statCard("星标", "\(s.starredCount)", "star.fill", .yellow)
                    statCard("归档", "\(s.archivedCount)", "archivebox", .secondary)
                    statCard("重复", "\(s.duplicateCount)", "doc.on.doc", .purple)
                    statCard("全文", "\(s.withFulltext)", "text.alignleft", .green)
                    statCard("已打分", "\(s.scored)", "number", .blue)
                    statCard("已翻译", "\(s.translated)", "globe", .teal)
                    statCard("DB 大小", String(format: "%.0f MB", s.dbSizeMB), "internaldrive", .secondary)
                }

                // 管线 job 分布
                VStack(alignment: .leading, spacing: 8) {
                    Text("管线处理（成功/失败）").font(.headline)
                    ForEach(jobTypes, id: \.jtype) { j in
                        HStack {
                            Text(j.jtype).frame(width: 90, alignment: .leading)
                            GeometryReader { geo in
                                let total = max(1, j.ok + j.failed)
                                HStack(spacing: 0) {
                                    Rectangle().fill(.green).frame(width: geo.size.width * CGFloat(j.ok) / CGFloat(total))
                                    Rectangle().fill(.red).frame(width: geo.size.width * CGFloat(j.failed) / CGFloat(total))
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .frame(height: 14)
                            Text("\(j.ok)/\(j.failed)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                // 内容最多的源
                VStack(alignment: .leading, spacing: 6) {
                    Text("内容最多的源 Top 10").font(.headline)
                    ForEach(Array(topSources.enumerated()), id: \.offset) { _, t in
                        HStack {
                            Text(t.name).lineLimit(1)
                            Spacer()
                            Text("\(t.count)").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear {
            // 统计查询后台跑：全表聚合在 67k 行库上有可见耗时，主线程执行会卡 UI
            Task.detached {
                let ov = StatsService.shared.overview()
                let jt = StatsService.shared.jobByType()
                let ts = StatsService.shared.topSources()
                await MainActor.run {
                    s = ov; jobTypes = jt; topSources = ts
                }
            }
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading) {
                Text(value).font(.title3.bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: 源健康

public struct SourceHealthPane: View {
    @State private var problems: [SourceHealth] = []

    public var body: some View {
        List {
            if problems.isEmpty {
                ContentUnavailableView("所有源健康", systemImage: "checkmark.seal",
                    description: Text("没有报错或停更的源"))
            }
            ForEach(problems) { h in
                HStack(spacing: 10) {
                    Image(systemName: h.hasError ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                        .foregroundStyle(h.hasError ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.name).font(.headline)
                        if let err = h.error {
                            Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                        }
                        if let hrs = h.hoursSinceFetch {
                            Text("上次抓取 \(Int(hrs)) 小时前 · \(h.contentCount) 条")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
        .onAppear { problems = SourceHealthService.shared.problemSources() }
    }
}

// MARK: 失败重试

public struct FailedJobPane: View {
    @State private var failures: [FailedJob] = []
    @State private var retrying: Set<Int64> = []

    public var body: some View {
        List {
            if failures.isEmpty {
                ContentUnavailableView("没有失败任务", systemImage: "checkmark.circle",
                    description: Text("管线运行正常"))
            }
            ForEach(failures) { job in
                HStack(spacing: 10) {
                    Text(job.jtype)
                        .font(.caption.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.red.opacity(0.15)).foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).font(.callout).lineLimit(1)
                        if let err = job.error {
                            Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        retrying.insert(job.id)
                        Task {
                            _ = await FailedJobService.shared.retry(job)
                            await MainActor.run {
                                retrying.remove(job.id)
                                failures = FailedJobService.shared.recentFailures()
                            }
                        }
                    } label: {
                        if retrying.contains(job.id) { ProgressView().scaleEffect(0.6) }
                        else { Text("重试") }
                    }
                    .controlSize(.small)
                    .disabled(retrying.contains(job.id))
                }
                .padding(.vertical, 3)
            }
        }
        .onAppear { failures = FailedJobService.shared.recentFailures() }
    }
}

// MARK: 标签管理

public struct TagManagePane: View {
    @State private var tagCounts: [(tag: Tag, count: Int)] = []
    @State private var newTag = ""

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("新建标签", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    if !newTag.trimmingCharacters(in: .whitespaces).isEmpty {
                        TagService.shared.addTag(name: newTag)
                        newTag = ""
                        reload()
                    }
                }
                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            List {
                ForEach(tagCounts, id: \.tag.id) { item in
                    HStack {
                        Image(systemName: "tag.fill").foregroundStyle(.blue)
                        Text(item.tag.name)
                        Spacer()
                        Text("\(item.count) 条").foregroundStyle(.secondary).font(.caption)
                        Button(role: .destructive) {
                            TagService.shared.removeTag(id: item.tag.id)
                            reload()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() { tagCounts = TagService.shared.tagCounts() }
}

// MARK: 过滤规则

public struct FilterRulePane: View {
    @State private var rules: [FilterRule] = []
    @State private var showAdd = false
    // 新规则表单
    @State private var rName = ""
    @State private var rField = "title"
    @State private var rMatch = "contains"
    @State private var rPattern = ""
    @State private var rAction = "archive"

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("命中规则的新内容将自动执行动作")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showAdd.toggle() } label: { Label("新建规则", systemImage: "plus") }
            }
            .padding()

            if showAdd {
                VStack(spacing: 8) {
                    TextField("规则名", text: $rName).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("字段", selection: $rField) {
                            Text("标题").tag("title"); Text("正文").tag("content")
                            Text("作者").tag("author"); Text("链接").tag("url")
                        }
                        Picker("匹配", selection: $rMatch) {
                            Text("包含").tag("contains"); Text("正则").tag("regex"); Text("前缀").tag("prefix")
                        }
                        Picker("动作", selection: $rAction) {
                            Text("归档").tag("archive"); Text("标已读").tag("mark_read")
                            Text("加星").tag("star")
                        }
                        .labelsHidden()
                    }
                    .labelsHidden()
                    TextField("匹配内容（关键词或正则）", text: $rPattern).textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("取消") { showAdd = false }
                        Button("保存") { saveRule() }.disabled(rName.isEmpty || rPattern.isEmpty)
                    }
                }
                .padding()
                .background(.quaternary.opacity(0.4))
                .padding(.horizontal)
            }

            List {
                ForEach(rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.headline)
                            Text("\(fieldLabel(rule.field)) \(matchLabel(rule.matchType)) 「\(rule.pattern)」 → \(actionLabel(rule.action))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { var r = rule; r.enabled = $0; FilterService.shared.updateRule(r); reload() }
                        )).labelsHidden()
                        Button(role: .destructive) {
                            FilterService.shared.removeRule(id: rule.id); reload()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private func saveRule() {
        let rule = FilterRule(id: 0, name: rName, field: rField, matchType: rMatch,
                              pattern: rPattern, action: rAction, sourceId: nil, enabled: true)
        FilterService.shared.addRule(rule)
        rName = ""; rPattern = ""; showAdd = false
        reload()
    }

    private func reload() { rules = FilterService.shared.allRules() }
    private func fieldLabel(_ f: String) -> String {
        ["title": "标题", "content": "正文", "author": "作者", "url": "链接"][f] ?? f
    }
    private func matchLabel(_ m: String) -> String {
        ["contains": "包含", "regex": "正则", "prefix": "前缀"][m] ?? m
    }
    private func actionLabel(_ a: String) -> String {
        if a.hasPrefix("tag:") { return "打标签「\(a.dropFirst(4))」" }
        return ["archive": "归档", "mark_read": "标已读", "star": "加星"][a] ?? a
    }
}

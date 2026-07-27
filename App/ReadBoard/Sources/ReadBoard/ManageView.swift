import SwiftUI

// MARK: - 管理面板
// 统一承载：统计概览 / 源健康 / 失败重试 / 过滤规则

public struct ManageView: View {
    @State private var tab = 0
    @EnvironmentObject private var appTab: AppTab

    public var body: some View {
        VStack(spacing: 0) {
            // 页头：返回 + 居中分段（三段式平衡布局）
            HStack {
                // 返回阅读（左栏底部导航切过来的入口）
                Button { appTab.selection = 0 } label: {
                    Label("阅读", systemImage: "chevron.left")
                }
                .buttonStyle(.quiet)
                .help("返回阅读")
                Spacer()
                Picker("", selection: $tab) {
                    Text("统计").tag(0)
                    Text("源健康").tag(1)
                    Text("失败重试").tag(2)
                    Text("过滤规则").tag(4)
                }
                .pickerStyle(.segmented)
                .tint(Color.rbAccent)
                .frame(maxWidth: 380)
                Spacer()
                // 右侧占位平衡返回按钮宽度，让分段真正居中
                Color.clear.frame(width: 64, height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

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
    @State private var exportRecords: [(platform: String, title: String, status: String, time: String)] = []

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 概览卡片（小图标 + 大数字 + 小标签的编辑部统计卡；hairline 描边无阴影）
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    statCard("订阅源", "\(s.enabledSources)/\(s.totalSources)", "dot.radiowaves.left.and.right", .rbAccent)
                    statCard("内容总数", "\(s.totalContent)", "doc.text", .rbText2)
                    statCard("未读", "\(s.unreadCount)", "circlebadge.fill", .rbAccent)
                    statCard("星标", "\(s.starredCount)", "star.fill", .rbStar)
                    statCard("归档", "\(s.archivedCount)", "archivebox", .rbText2)
                    statCard("重复", "\(s.duplicateCount)", "doc.on.doc", .rbSummary)
                    statCard("全文", "\(s.withFulltext)", "text.alignleft", .rbScoreHigh)
                    statCard("已 AI 评分", "\(s.scored)", "number", .rbAccent)
                    statCard("已翻译", "\(s.translated)", "globe", .rbTranslate)
                    statCard("DB 大小", String(format: "%.0f MB", s.dbSizeMB), "internaldrive", .rbText2)
                }

                // 管线 job 分布
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "管线处理（成功/失败）")
                    ForEach(jobTypes, id: \.jtype) { j in
                        HStack(spacing: 10) {
                            Text(j.jtype)
                                .font(.caption)
                                .foregroundStyle(Color.rbText2)
                                .frame(width: 90, alignment: .leading)
                            GeometryReader { geo in
                                let total = max(1, j.ok + j.failed)
                                HStack(spacing: 0) {
                                    Rectangle().fill(Color.rbScoreHigh).frame(width: geo.size.width * CGFloat(j.ok) / CGFloat(total))
                                    Rectangle().fill(Color.rbScoreLow).frame(width: geo.size.width * CGFloat(j.failed) / CGFloat(total))
                                }
                                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
                            }
                            .frame(height: 10)
                            Text("\(j.ok)/\(j.failed)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.rbText3)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }

                // 内容最多的源
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "内容最多的源 Top 10")
                    VStack(spacing: 0) {
                        ForEach(topSources.indices, id: \.self) { idx in
                            let t = topSources[idx]
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.rbText3)
                                    .frame(width: 20, alignment: .trailing)
                                Text(t.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.rbText)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(t.count)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.rbText3)
                            }
                            .padding(.vertical, 7)
                            if idx < topSources.count - 1 {
                                Hairline()
                            }
                        }
                    }
                }

                // 导出记录（各平台导出历史）
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "导出记录")
                    if exportRecords.isEmpty {
                        Text("暂无导出记录")
                            .font(.caption)
                            .foregroundStyle(Color.rbText3)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(exportRecords.indices, id: \.self) { idx in
                                let r = exportRecords[idx]
                                HStack(spacing: 10) {
                                    Text(r.platform)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.rbText2)
                                        .frame(width: 80, alignment: .leading)
                                    Text(r.title)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.rbText)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(r.status)
                                        .font(.caption)
                                        .foregroundStyle(r.status == "delivered" ? Color.rbScoreHigh : Color.rbScoreLow)
                                        .frame(width: 60, alignment: .trailing)
                                    Text(r.time)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Color.rbText3)
                                        .frame(width: 70, alignment: .trailing)
                                }
                                .padding(.vertical, 6)
                                if idx < exportRecords.count - 1 {
                                    Hairline()
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            // 统计查询后台跑：全表聚合在 67k 行库上有可见耗时，主线程执行会卡 UI
            Task.detached {
                let ov = StatsService.shared.overview()
                let jt = StatsService.shared.jobByType()
                let ts = StatsService.shared.topSources()
                let er = StatsService.shared.exportRecords()
                await MainActor.run {
                    s = ov; jobTypes = jt; topSources = ts; exportRecords = er
                }
            }
        }
    }

    /// 统计卡：小图标（降饱和语义色）+ 大数字（等宽）+ 小标签，hairline 描边
    private func statCard(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .default).monospacedDigit())
                .foregroundStyle(Color.rbText)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.rbSurface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RB.Radius.lg)
                .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
        )
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
                        .foregroundStyle(h.hasError ? Color.rbScoreLow : Color.rbScoreMid)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.rbText)
                        if let err = h.error {
                            Text(err).font(.caption).foregroundStyle(Color.rbScoreLow).lineLimit(1)
                        }
                        if let hrs = h.hoursSinceFetch {
                            Text("上次抓取 \(Int(hrs)) 小时前 · \(h.contentCount) 条")
                                .font(.caption).foregroundStyle(Color.rbText3)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
        // 后台查库——67k 行库主线程同步查询会卡首帧（修 P2-12）
        .task {
            let r = await Task.detached(priority: .userInitiated) {
                SourceHealthService.shared.problemSources()
            }.value
            problems = r
        }
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
                    RBadge(text: job.jtype, color: .rbScoreLow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).font(.callout).foregroundStyle(Color.rbText).lineLimit(1)
                        if let err = job.error {
                            Text(err).font(.caption).foregroundStyle(Color.rbText3).lineLimit(1)
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
                    .buttonStyle(.quiet)
                    .disabled(retrying.contains(job.id))
                }
                .padding(.vertical, 3)
            }
        }
        .task {
            let r = await Task.detached(priority: .userInitiated) {
                FailedJobService.shared.recentFailures()
            }.value
            failures = r
        }
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
                .buttonStyle(.primaryCapsule)
                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            List {
                ForEach(tagCounts, id: \.tag.id) { item in
                    HStack {
                        Image(systemName: "tag.fill").foregroundStyle(Color.rbAccent)
                        Text(item.tag.name).foregroundStyle(Color.rbText)
                        Spacer()
                        Text("\(item.count) 条")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.rbText3)
                        Button(role: .destructive) {
                            TagService.shared.removeTag(id: item.tag.id)
                            reload()
                        } label: { Image(systemName: "trash").foregroundStyle(Color.rbText3) }
                        .buttonStyle(.quiet)
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
                    .font(.caption).foregroundStyle(Color.rbText3)
                Spacer()
                Button { showAdd.toggle() } label: { Label("新建规则", systemImage: "plus") }
                    .buttonStyle(.quiet)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if showAdd {
                VStack(spacing: 10) {
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
                    .tint(Color.rbAccent)
                    TextField("匹配内容（关键词或正则）", text: $rPattern).textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("取消") { showAdd = false }
                            .buttonStyle(.quiet)
                        Button("保存") { saveRule() }
                            .buttonStyle(.primaryCapsule)
                            .disabled(rName.isEmpty || rPattern.isEmpty)
                    }
                }
                .padding(14)
                .background(Color.rbSurface.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RB.Radius.lg)
                        .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            List {
                ForEach(rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.rbText)
                            Text("\(fieldLabel(rule.field)) \(matchLabel(rule.matchType)) 「\(rule.pattern)」 → \(actionLabel(rule.action))")
                                .font(.caption).foregroundStyle(Color.rbText3)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { var r = rule; r.enabled = $0; FilterService.shared.updateRule(r); reload() }
                        )).labelsHidden().tint(Color.rbAccent)
                        Button(role: .destructive) {
                            FilterService.shared.removeRule(id: rule.id); reload()
                        } label: { Image(systemName: "trash").foregroundStyle(Color.rbText3) }
                        .buttonStyle(.quiet)
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

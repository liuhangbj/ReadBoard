import Foundation
import CryptoKit

public final class ExportPlatformConfig: @unchecked Sendable {
    static let shared = ExportPlatformConfig(); private init() {}
    var obsidianDir: String { get { UserDefaults.standard.string(forKey: "export.obsidian.dir") ?? "" } set { UserDefaults.standard.set(newValue, forKey: "export.obsidian.dir") } }
    var webhookURL: String { get { UserDefaults.standard.string(forKey: "export.webhook.url") ?? "" } set { UserDefaults.standard.set(newValue, forKey: "export.webhook.url") } }
    var webhookHeaders: [String:String] { get { guard let d=UserDefaults.standard.data(forKey:"export.webhook.headers"), let o=try? JSONSerialization.jsonObject(with:d) as? [String:String] else {return[:]}; return o } set { if let d=try? JSONSerialization.data(withJSONObject:newValue){UserDefaults.standard.set(d,forKey:"export.webhook.headers")} } }
    func isEnabled(_ p: String) -> Bool { UserDefaults.standard.bool(forKey: "export.\(p).enabled") }
    func setEnabled(_ p: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: "export.\(p).enabled") }
}

public struct ExportRule: Identifiable {
    public let id: Int64; var name: String; var enabled: Bool; var criteria: Criteria
    var triggerOn: String; var target: String; var targetConfig: [String:Any]
    var overwrite = true; var frontmatterFields: [String]?; var frontmatterLabels: [String:String]?
    var useTranslatedTitle = false; var titleTemplate = "{title}-{id}"; var lastRunAt: String?
    var revision = 1; var artifact = "original"; var missingPolicy = "wait"
    var outputFormat = "markdown"; var subfolderTemplate = ""; var writePolicy = "overwrite"
    var historyScope = "all"; var attachmentsPolicy = "remote"; var createdAt: String?
    var historyAfter: String?  // 指定日期之后（custom_date 时使用）
    static func == (lhs: ExportRule, rhs: ExportRule) -> Bool { lhs.id == rhs.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    struct Criteria: Hashable {
        var minScore: Int?; var sourceIds: [Int64]?; var folderIds: [Int64]?
        var requireTranslated=false; var requireTranscribed=false; var requireSummary=false; var requireScored=false
        var starredOnly=false; var readStatus: String?; var keywords: [String]?; var contentTypes: [String]?
        var languages: [String]?; var platforms: [String]?; var excludedSourceIds: [Int64]?
        var excludedKeywords: [String]?; var publishedAfter: String?; var publishedBefore: String?
        static func from(json: String) -> Criteria {
            var c=Criteria(); guard let o=(try? JSONSerialization.jsonObject(with:Data(json.utf8))) as? [String:Any] else {return c}
            c.minScore=o["min_score"] as? Int; c.sourceIds=(o["source_ids"] as? [NSNumber])?.map{$0.int64Value}
            c.folderIds=(o["folder_ids"] as? [NSNumber])?.map{$0.int64Value}
            c.requireTranslated=o["require_translated"] as? Bool ?? false; c.requireTranscribed=o["require_transcribed"] as? Bool ?? false
            c.requireSummary=o["require_summary"] as? Bool ?? false; c.requireScored=o["require_scored"] as? Bool ?? false
            c.starredOnly=o["starred_only"] as? Bool ?? false; c.readStatus=o["read_status"] as? String
            c.keywords=o["keywords"] as? [String]; c.contentTypes=o["content_types"] as? [String]
            c.languages=o["languages"] as? [String]; c.platforms=o["platforms"] as? [String]
            c.excludedSourceIds=(o["excluded_source_ids"] as? [NSNumber])?.map{$0.int64Value}
            c.excludedKeywords=o["excluded_keywords"] as? [String]
            c.publishedAfter=o["published_after"] as? String; c.publishedBefore=o["published_before"] as? String
            return c
        }
        func toJSON() -> String {
            var o:[String:Any]=[:]; if let s=minScore{o["min_score"]=s}; if let ids=sourceIds{o["source_ids"]=ids}
            if let fids=folderIds{o["folder_ids"]=fids}
            if requireTranslated{o["require_translated"]=true}; if requireTranscribed{o["require_transcribed"]=true}
            if requireSummary{o["require_summary"]=true}; if requireScored{o["require_scored"]=true}
            if starredOnly{o["starred_only"]=true}; if let rs=readStatus{o["read_status"]=rs}
            if let kw=keywords{o["keywords"]=kw}; if let ct=contentTypes{o["content_types"]=ct}
            if let lang=languages{o["languages"]=lang}; if let p=platforms{o["platforms"]=p}
            if let ids=excludedSourceIds{o["excluded_source_ids"]=ids}; if let kw=excludedKeywords{o["excluded_keywords"]=kw}
            if let a=publishedAfter{o["published_after"]=a}; if let b=publishedBefore{o["published_before"]=b}
            return (try? JSONSerialization.data(withJSONObject:o,options:[.sortedKeys])).flatMap{String(data:$0,encoding:.utf8)} ?? "{}"
        }
    }
    var triggerDisplay: String { switch ExportRule.normalizedTrigger(triggerOn){case "ready":return "加工完成后";case "starred":return "加星标时";case "scheduled":return "定时导出";case "ingest":return "入库后";default:return "手动执行"} }
    var targetDisplay: String { switch target{case "obsidian":return "Obsidian";case "mddir":return "Markdown目录";case "webhook":return "Webhook";default:return target} }
    static func normalizedTrigger(_ t: String) -> String { switch t{case "score","translate","transcribe":return "ready";case "ready","starred","scheduled","manual","ingest":return t;default:return "manual"} }
    var effectiveArtifact: String { if artifact != "original" {return artifact}; return targetConfig["view"] as? String ?? targetConfig["artifact"] as? String ?? "original" }
    var effectiveSubfolderTemplate: String { if !subfolderTemplate.isEmpty{return subfolderTemplate}; if let l=targetConfig["subfolder"] as? String,!l.isEmpty{return l}; return "" }
    var effectiveWritePolicy: String { if writePolicy != "overwrite"{return writePolicy}; if overwrite == false{return "versioned"}; return "overwrite" }
}

public struct ExportRulePreview: Sendable {
    public struct Sample: Sendable { public let contentId: Int64; public let title: String; public let markdown: String?; public let destination: String?; public let issue: String? }
    public let matchingCount: Int; public let samples: [Sample]
}

public final class ExportService: @unchecked Sendable {
    static let shared = ExportService(); private let db = Database.shared
    private let sLock=NSLock(); private var sTask: Task<Void,Never>?; private let rLock=NSLock(); private var rIds=Set<Int64>()
    private let webhookSessionLock = NSLock(); private var webhookSession = URLSession.shared
    private init() {}

    func listRules() -> [ExportRule] { db.queryRows("SELECT id,name,enabled,criteria,trigger_on,target,target_config,last_run_at,revision,artifact,missing_policy,output_format,subfolder_template,filename_template,write_policy,history_scope,frontmatter_fields,attachments_policy,created_at FROM export_rule ORDER BY id").map{r in var rule=ExportRule(id:Int64(r["id"] ?? "") ?? 0,name:r["name"] ?? "未命名",enabled:r["enabled"]=="1",criteria:ExportRule.Criteria.from(json:r["criteria"] ?? "{}"),triggerOn:ExportRule.normalizedTrigger(r["trigger_on"] ?? "manual"),target:r["target"] ?? "mddir",targetConfig:((try? JSONSerialization.jsonObject(with:Data((r["target_config"] ?? "{}").utf8))) as? [String:Any]) ?? [:],lastRunAt:r["last_run_at"]); rule.revision=Int(r["revision"] ?? "") ?? 1; rule.artifact=r["artifact"] ?? "original"; rule.missingPolicy=r["missing_policy"] ?? "wait"; rule.outputFormat=r["output_format"] ?? "markdown"; rule.subfolderTemplate=r["subfolder_template"] ?? ""; rule.titleTemplate=r["filename_template"] ?? "{title}-{id}"; rule.writePolicy=r["write_policy"] ?? "overwrite"; rule.overwrite=rule.writePolicy=="overwrite"; rule.historyScope=r["history_scope"] ?? "all"; rule.frontmatterFields=Self.decodeSA(r["frontmatter_fields"]); rule.attachmentsPolicy=r["attachments_policy"] ?? "remote"; rule.createdAt=r["created_at"]; rule.useTranslatedTitle=rule.targetConfig["use_translated_title"] as? Bool ?? false; rule.frontmatterLabels=rule.targetConfig["frontmatter_labels"] as? [String:String]; rule.historyAfter=rule.targetConfig["history_after"] as? String; return rule } }

    @discardableResult func saveRule(_ rule: ExportRule) -> Int64 {
        var n=rule; n.triggerOn=ExportRule.normalizedTrigger(rule.triggerOn); n.artifact=rule.effectiveArtifact; n.subfolderTemplate=rule.effectiveSubfolderTemplate; n.writePolicy=rule.effectiveWritePolicy
        n.targetConfig["view"]=n.artifact; n.targetConfig["subfolder"]=n.subfolderTemplate; n.targetConfig["overwrite"]=n.writePolicy=="overwrite"
        n.targetConfig["use_translated_title"]=rule.useTranslatedTitle; if let l=rule.frontmatterLabels{n.targetConfig["frontmatter_labels"]=l}; if let ha=rule.historyAfter{n.targetConfig["history_after"]=ha}
        let cj=(try? JSONSerialization.data(withJSONObject:n.targetConfig,options:[.sortedKeys])).flatMap{String(data:$0,encoding:.utf8)} ?? "{}"
        let fj=Self.encodeSA(n.frontmatterFields ?? Self.dfFields); let cur=rule.id>0 ? listRules().first{$0.id==rule.id} : nil
        if rule.id>0 { let rev=(cur.map{deliveryFP($0) != deliveryFP(n)} ?? false) ? max(1,(cur?.revision ?? 1)+1) : max(1,cur?.revision ?? n.revision)
            db.execute("UPDATE export_rule SET name=?,enabled=?,criteria=?,trigger_on=?,target=?,target_config=?,revision=?,artifact=?,missing_policy=?,output_format=?,subfolder_template=?,filename_template=?,write_policy=?,history_scope=?,frontmatter_fields=?,attachments_policy=? WHERE id=?",params:[n.name,n.enabled ? 1:0,n.criteria.toJSON(),n.triggerOn,n.target,cj,rev,n.artifact,n.missingPolicy,n.outputFormat,n.subfolderTemplate,n.titleTemplate,n.writePolicy,n.historyScope,fj,n.attachmentsPolicy,n.id]); return rule.id }
        db.execute("INSERT INTO export_rule(name,enabled,criteria,trigger_on,target,target_config,revision,artifact,missing_policy,output_format,subfolder_template,filename_template,write_policy,history_scope,frontmatter_fields,attachments_policy)VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",params:[n.name,n.enabled ? 1:0,n.criteria.toJSON(),n.triggerOn,n.target,cj,max(1,n.revision),n.artifact,n.missingPolicy,n.outputFormat,n.subfolderTemplate,n.titleTemplate,n.writePolicy,n.historyScope,fj,n.attachmentsPolicy]); return db.lastInsertId() }
    func deleteRule(id: Int64) { db.execute("DELETE FROM export_rule WHERE id=?",params:[id]) }
    func statsFor(ruleId: Int64) -> (delivered:Int,failed:Int) {
        // export_record 保留各次规则修订的审计历史；界面统计的是不同内容，不能把
        // 同一篇文章在多个 revision 下的交付记录重复计算。
        let delivered = db.scalarInt(
            "SELECT COUNT(DISTINCT content_id) FROM export_record WHERE rule_id=? AND status='delivered'",
            params: [ruleId]) ?? 0
        let failed = db.scalarInt(
            "SELECT COUNT(DISTINCT content_id) FROM export_record WHERE rule_id=? AND status='failed'",
            params: [ruleId]) ?? 0
        return (delivered, failed)
    }

    func runPending(trigger: String, contentId: Int64?=nil) async { guard FeatureBoard.export.enabled else {return}; let nt=ExportRule.normalizedTrigger(trigger); for rule in listRules() where rule.enabled && ExportRule.normalizedTrigger(rule.triggerOn)==nt { if nt=="scheduled",!isDue(rule){continue}; await run(rule:rule,contentId:contentId)} }
    func runFor(ruleId: Int64) async { guard let rule=listRules().first(where:{$0.id==ruleId}) else {return}; await run(rule:rule,contentId:nil) }

    /// 强制导出：忽略触发时机，对所有启用的规则逐条评估并导出该篇。
    func forceExport(contentId: Int64) async -> Int {
        var done = 0
        for rule in listRules() where rule.enabled {
            await run(rule: rule, contentId: contentId)
            done += 1
        }
        return done
    }
    func startScheduler(intervalSeconds: TimeInterval=300) { sLock.lock();defer{sLock.unlock()}; guard sTask==nil else{return}; sTask=Task{[weak self] in do{try await Task.sleep(nanoseconds:5_000_000_000)}catch{return}; while !Task.isCancelled{guard !Task.isCancelled,let self else{break}; await self.runPending(trigger:"scheduled"); do{try await Task.sleep(nanoseconds:UInt64(max(30,intervalSeconds)*1_000_000_000))}catch{break}} } }
    func stopScheduler() { sLock.lock();let t=sTask;sTask=nil;sLock.unlock();t?.cancel() }

    func preview(rule: ExportRule, maxSamples: Int=3) -> ExportRulePreview {
        var beforeId: Int64?
        var count = 0
        var samples: [ExportRulePreview.Sample] = []
        let fields = rule.frontmatterFields ?? Self.dfFields
        let configurationIssue = deliveryConfigurationIssue(for: rule)
        repeat {
            let page = matching(rule: rule, contentId: nil, beforeId: beforeId)
            guard !page.isEmpty else { break }
            count += page.count
            for content in page where samples.count < max(0, maxSamples) {
                var markdown = renderMD(content: content, view: rule.effectiveArtifact,
                                        fields: fields, labels: rule.frontmatterLabels,
                                        useTT: rule.useTranslatedTitle)
                if markdown == nil && rule.missingPolicy == "fallback_original" {
                    markdown = renderMD(content: content, view: "original", fields: fields,
                                        labels: rule.frontmatterLabels,
                                        useTT: rule.useTranslatedTitle)
                }
                var destination: String?
                var issue = configurationIssue
                if issue == nil && markdown == nil {
                    issue = "缺少文稿"
                } else if issue == nil && rule.target == "webhook" {
                    destination = ExportPlatformConfig.shared.webhookURL
                } else if issue == nil && (rule.target == "obsidian" || rule.target == "mddir") {
                    let root = rule.target == "obsidian"
                        ? ExportPlatformConfig.shared.obsidianDir
                        : (rule.targetConfig["dir"] as? String ?? "")
                    do {
                        destination = try destURL(content: content, vaultRoot: root,
                                                  subTpl: rule.effectiveSubfolderTemplate,
                                                  fileTpl: rule.titleTemplate,
                                                  useTranslatedTitle: rule.useTranslatedTitle).path
                    } catch {
                        issue = error.localizedDescription
                    }
                }
                samples.append(.init(contentId: content.id, title: content.title,
                                     markdown: markdown, destination: destination, issue: issue))
            }
            beforeId = page.last?.id
        } while beforeId != nil
        return ExportRulePreview(matchingCount: count, samples: samples)
    }

    func deliverSingle(rule: ExportRule, contentId: Int64) async -> (Bool,String?,String?) {
        guard platformIsEnabled(rule.target) else { return (false, nil, platformDisabledMessage(rule.target)) }
        guard let content = loadEC(id: contentId) else { return (false, nil, "内容不存在") }
        let result = await deliver(rule: rule, c: content)
        return (result.status == "delivered" || result.status == "skipped",
                result.destination, result.error)
    }
    func renderForExport(contentId: Int64, view: String) -> String? { guard let c=loadEC(id:contentId) else{return nil}; return renderMD(content:c,view:view,fields:Self.dfFields) }
    static func sanitizeFilename(_ name:String) -> String { var s=name.replacingOccurrences(of:"[/\\\\:\\*\\?\"<>\\|]",with:"",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines); if s.isEmpty{s="untitled"}; if s.count>180{s=String(s.prefix(180))}; return s }
    static func stripLeadingFrontmatter(_ text:String) -> String { let t=text.trimmingCharacters(in:.whitespacesAndNewlines); guard t.hasPrefix("---") else{return text}; var lines=t.components(separatedBy:"\n"); guard lines.count>2 else{return text}; lines.removeFirst(); if let end=lines.firstIndex(where:{$0.trimmingCharacters(in:.whitespaces)=="---"}){return lines[(end+1)...].joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)}; return text }

    #if DEBUG
    func scheduledRuleIsDueForTesting(_ rule: ExportRule, now: Date) -> Bool { guard let last=rule.lastRunAt,!last.isEmpty else{return true}; let f=DateFormatter();f.dateFormat="yyyy-MM-dd HH:mm:ss";f.timeZone=TimeZone(secondsFromGMT:0); guard let d=f.date(from:last) else{return true}; let freq=rule.targetConfig["schedule_interval"] as? String ?? "daily"; let interval:TimeInterval = freq=="hourly" ? 3600 : freq=="weekly" ? 604800 : 86400; return now.timeIntervalSince(d) >= interval }
    func setWebhookSessionForTesting(_ session: URLSession?) {
        webhookSessionLock.lock(); webhookSession = session ?? .shared; webhookSessionLock.unlock()
    }
    #endif

    // MARK: internal
    private func run(rule: ExportRule, contentId: Int64?) async {
        // 平台总开关用于暂停整个平台；暂停不记失败，也不更新规则执行时间。
        guard platformIsEnabled(rule.target) else { return }
        guard beginRR(rule.id) else { return }
        defer { endRR(rule.id) }

        var beforeId: Int64?
        exportPages: while !Task.isCancelled {
            let candidates = matching(rule: rule, contentId: contentId, beforeId: beforeId)
            guard !candidates.isEmpty else { break }

            for content in candidates {
                guard !Task.isCancelled else { break exportPages }
                let result = await deliver(rule: rule, c: content)
                db.execute("INSERT INTO export_record(rule_id,content_id,artifact,revision,status,destination,error,rendered_hash,attempts,updated_at)VALUES(?,?,?,?,?,?,?,?,?,datetime('now'))ON CONFLICT(rule_id,content_id,artifact,revision)DO UPDATE SET status=excluded.status,destination=COALESCE(excluded.destination,export_record.destination),error=excluded.error,rendered_hash=COALESCE(excluded.rendered_hash,export_record.rendered_hash),attempts=export_record.attempts+excluded.attempts,updated_at=datetime('now')",
                           params: [rule.id, content.id, rule.effectiveArtifact, rule.revision,
                                    result.status, result.destination, result.error,
                                    result.renderedHash, result.didAttempt ? 1 : 0])
            }

            // ID 游标分页直到候选为空；200 只是单页大小，不再是 2000 条总上限。
            beforeId = candidates.last?.id
            await Task.yield()
        }

        // 被取消的执行不算完整跑完，避免定时规则据此推迟下一次补跑。
        guard !Task.isCancelled else { return }
        db.execute("UPDATE export_rule SET last_run_at=datetime('now') WHERE id=?", params: [rule.id])
    }

    private func matching(rule: ExportRule, contentId: Int64?, beforeId: Int64?) -> [EC] {
        var w:[String]=["is_duplicate=0","deleted_at IS NULL"];var p:[Any?]=[]; if let cid=contentId{w.append("id=?");p.append(cid)}; if let bid=beforeId{w.append("id<?");p.append(bid)}
        if let ms=rule.criteria.minScore{w.append("llm_score>=?");p.append(ms)}; if rule.criteria.requireScored{w.append("llm_score IS NOT NULL")}
        if let ids=rule.criteria.sourceIds,!ids.isEmpty{w.append("source_id IN (\(ids.map{String($0)}.joined(separator:",")))")}
        if rule.criteria.requireTranslated{w.append("llm_translated_md IS NOT NULL AND llm_translated_md!=''")}
        if rule.criteria.requireTranscribed{w.append("llm_transcript_md IS NOT NULL AND llm_transcript_md!=''")}
        if rule.criteria.requireSummary{w.append("llm_summary IS NOT NULL AND llm_summary!=''")}
        if rule.criteria.starredOnly{w.append("starred=1")}
        if let fids=rule.criteria.folderIds,!fids.isEmpty{w.append("source_id IN (SELECT id FROM content_source WHERE folder_id IN (\(fids.map{String($0)}.joined(separator:","))))")}
        if let rs=rule.criteria.readStatus{w.append(rs=="read" ? "read_at IS NOT NULL" : "read_at IS NULL")}
        if let kws=rule.criteria.keywords{for kw in kws{w.append("(title LIKE ? OR content_md LIKE ? OR excerpt LIKE ?)");p.append("%\(kw)%");p.append("%\(kw)%");p.append("%\(kw)%")}}
        if let cts=rule.criteria.contentTypes,!cts.isEmpty{w.append("ctype IN (\(cts.map{_ in "?"}.joined(separator:",")))");p.append(contentsOf:cts)}
        if let langs=rule.criteria.languages,!langs.isEmpty{w.append("language IN (\(langs.map{_ in "?"}.joined(separator:",")))");p.append(contentsOf:langs)}
        if let plats=rule.criteria.platforms,!plats.isEmpty{w.append("source IN (\(plats.map{_ in "?"}.joined(separator:",")))");p.append(contentsOf:plats)}
        if let eids=rule.criteria.excludedSourceIds,!eids.isEmpty{w.append("(source_id IS NULL OR source_id NOT IN (\(eids.map{_ in "?"}.joined(separator:","))))");p.append(contentsOf:eids)}
        if let eks=rule.criteria.excludedKeywords{for kw in eks where !kw.isEmpty{w.append("NOT (title LIKE ? OR content_md LIKE ? OR excerpt LIKE ?)");p.append("%\(kw)%");p.append("%\(kw)%");p.append("%\(kw)%")}}
        if let a=rule.criteria.publishedAfter,!a.isEmpty {
            w.append("published_at>=?")
            p.append(Self.calendarDay(from: a) ?? a)
        }
        if let b=rule.criteria.publishedBefore,!b.isEmpty {
            if let nextDay = Self.dayAfter(b) {
                // 使用次日的排他上界；两种常见存储格式都以 YYYY-MM-DD 开头，
                // 因而无需对列调用 datetime()，还能保留 published_at 索引的使用机会。
                w.append("published_at<?")
                p.append(nextDay)
            } else {
                w.append("published_at<=?")
                p.append(b)
            }
        }
        if rule.historyScope=="new_only"{let ca=rule.createdAt?.isEmpty==false ? rule.createdAt! : ISO8601DateFormatter().string(from:Date()); w.append("created_at>=?");p.append(ca)} else if rule.historyScope=="custom_date", let ha=rule.historyAfter,!ha.isEmpty{w.append("created_at>=?");p.append(ha)}
        let sql="SELECT id,title,url,source,author,llm_score,llm_summary,llm_translated_md,llm_transcript_md,content_md,excerpt,published_at,ctype,language,llm_title_translated FROM content WHERE \(w.joined(separator:" AND ")) ORDER BY id DESC LIMIT 200"
        return db.queryRows(sql,params:p).map{r in EC(id:Int64(r["id"] ?? "") ?? 0,title:r["title"] ?? "",url:r["url"] ?? "",source:r["source"] ?? "",author:r["author"] ?? "",ctype:r["ctype"] ?? "article",language:r["language"] ?? "",score:Int(r["llm_score"] ?? ""),summary:r["llm_summary"],translated:r["llm_translated_md"],transcript:r["llm_transcript_md"],contentMd:r["content_md"],excerpt:r["excerpt"],titleTranslated:r["llm_title_translated"],publishedAt:r["published_at"] ?? "")}
    }

    private struct EC { let id:Int64;let title,url,source,author:String;let ctype,language:String;let score:Int?;let summary,translated,transcript,contentMd,excerpt:String?;let titleTranslated:String?;let publishedAt:String }
    private func loadEC(id: Int64) -> EC? { guard let r=db.queryRows("SELECT id,title,url,source,author,llm_score,llm_summary,llm_translated_md,llm_transcript_md,content_md,excerpt,published_at,ctype,language,llm_title_translated FROM content WHERE id=?",params:[id]).first else{return nil}; return EC(id:Int64(r["id"] ?? "") ?? 0,title:r["title"] ?? "",url:r["url"] ?? "",source:r["source"] ?? "",author:r["author"] ?? "",ctype:r["ctype"] ?? "article",language:r["language"] ?? "",score:Int(r["llm_score"] ?? ""),summary:r["llm_summary"],translated:r["llm_translated_md"],transcript:r["llm_transcript_md"],contentMd:r["content_md"],excerpt:r["excerpt"],titleTranslated:r["llm_title_translated"],publishedAt:r["published_at"] ?? "") }
    private struct DR { let status:String;let destination:String?;let error:String?;let renderedHash:String?;let didAttempt:Bool }

    private func deliver(rule: ExportRule, c: EC) async -> DR {
        guard platformIsEnabled(rule.target) else {
            return DR(status: "failed", destination: nil, error: platformDisabledMessage(rule.target),
                      renderedHash: nil, didAttempt: false)
        }
        let artifact=rule.effectiveArtifact;let fields=rule.frontmatterFields ?? Self.dfFields;let labels=rule.frontmatterLabels;let utt=rule.useTranslatedTitle
        var md=renderMD(content:c,view:artifact,fields:fields,labels:labels,useTT:utt); if md==nil && rule.missingPolicy=="fallback_original"{md=renderMD(content:c,view:"original",fields:fields,labels:labels,useTT:utt)}
        guard let md else{let st=rule.missingPolicy=="skip" ? "skipped":"waiting";return DR(status:st,destination:nil,error:"缺少文稿",renderedHash:nil,didAttempt:false)}
        let hash = deliveryHash(markdown: md, rule: rule)
        if rule.id>0,let _=db.queryRows("SELECT destination FROM export_record WHERE rule_id=? AND content_id=? AND artifact=? AND revision=? AND status='delivered' AND rendered_hash=? LIMIT 1",params:[rule.id,c.id,artifact,rule.revision,hash]).first{return DR(status:"delivered",destination:nil,error:nil,renderedHash:hash,didAttempt:false)}
        if rule.target == "webhook" {
            return await postWebhook(rule: rule, content: c, markdown: md, renderedHash: hash)
        }
        guard rule.target == "obsidian" || rule.target == "mddir" else {
            return DR(status: "failed", destination: nil, error: "不支持的导出平台：\(rule.target)",
                      renderedHash: hash, didAttempt: false)
        }
        let dir = rule.target == "obsidian"
            ? ExportPlatformConfig.shared.obsidianDir
            : (rule.targetConfig["dir"] as? String ?? "")
        guard !dir.isEmpty else{return DR(status:"failed",destination:nil,error:"目录未配置",renderedHash:hash,didAttempt:false)}
        let t=writeMD(md:md,content:c,vaultRoot:dir,subTpl:rule.effectiveSubfolderTemplate,fileTpl:rule.titleTemplate,writePolicy:rule.effectiveWritePolicy,useTranslatedTitle:rule.useTranslatedTitle)
        return DR(status:t.0 ? "delivered":"failed",destination:t.1,error:t.2,renderedHash:hash,didAttempt:true)
    }

    private func postWebhook(rule: ExportRule, content: EC, markdown: String,
                             renderedHash: String) async -> DR {
        let config = ExportPlatformConfig.shared
        let endpoint = config.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return DR(status: "failed", destination: nil, error: "Webhook URL 无效",
                      renderedHash: renderedHash, didAttempt: false)
        }

        let displayTitle = rule.useTranslatedTitle && content.titleTranslated?.isEmpty == false
            ? content.titleTranslated! : content.title
        var contentPayload: [String: Any] = [
            "id": content.id,
            "title": displayTitle,
            "url": content.url,
            "source": content.source,
            "content_type": content.ctype,
            "language": content.language,
            "published_at": content.publishedAt
        ]
        if let score = content.score { contentPayload["score"] = score }
        var payload: [String: Any] = [
            "event": "readboard.export",
            "rule_id": rule.id,
            "rule_revision": rule.revision,
            "artifact": rule.effectiveArtifact,
            "format": "markdown",
            "rendered_hash": renderedHash,
            "content": contentPayload,
            "markdown": markdown
        ]
        if let summary = content.summary, !summary.isEmpty { payload["summary"] = summary }
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return DR(status: "failed", destination: nil, error: "Webhook 请求编码失败",
                      renderedHash: renderedHash, didAttempt: false)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("ReadBoard", forHTTPHeaderField: "User-Agent")
        for (key, value) in config.webhookHeaders where !key.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await currentWebhookSession().data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return DR(status: "failed", destination: endpoint, error: "Webhook 未返回 HTTP 响应",
                          renderedHash: renderedHash, didAttempt: true)
            }
            guard (200..<300).contains(http.statusCode) else {
                let responseText = String(data: Data(data.prefix(500)), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = responseText?.isEmpty == false ? "：\(responseText!)" : ""
                return DR(status: "failed", destination: endpoint,
                          error: "Webhook HTTP \(http.statusCode)\(suffix)",
                          renderedHash: renderedHash, didAttempt: true)
            }
            return DR(status: "delivered", destination: endpoint, error: nil,
                      renderedHash: renderedHash, didAttempt: true)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return DR(status: "waiting", destination: endpoint, error: nil,
                          renderedHash: renderedHash, didAttempt: false)
            }
            return DR(status: "failed", destination: endpoint,
                      error: "Webhook 请求失败：\(error.localizedDescription)",
                      renderedHash: renderedHash, didAttempt: true)
        }
    }

    private func renderMD(content: EC, view: String, fields: [String], labels: [String:String]?=nil, useTT: Bool=false) -> String? {
        let orig=[content.contentMd,content.excerpt].compactMap{$0?.trimmingCharacters(in:.whitespacesAndNewlines)}.first{!$0.isEmpty} ?? ""
        let trans=content.translated?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""; let trscr=content.transcript?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let sum=content.summary?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let body: String; switch view{case "translated":guard !trans.isEmpty else{return nil};body=trans; case "transcript":guard !trscr.isEmpty else{return nil};body=trscr; case "summary":guard !sum.isEmpty else{return nil};body=sum; case "summary_original":guard !sum.isEmpty,!orig.isEmpty else{return nil};body="## 摘要\n\n\(sum)\n\n## 原文\n\n\(orig)"; case "summary_translated":guard !sum.isEmpty,!trans.isEmpty else{return nil};body="## 摘要\n\n\(sum)\n\n## 译文\n\n\(trans)"; case "summary_transcript":guard !sum.isEmpty,!trscr.isEmpty else{return nil};body="## 摘要\n\n\(sum)\n\n## 转录稿\n\n\(trscr)"; default:guard !orig.isEmpty else{return nil};body=orig}
        func y(_ v:String)->String{v.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\r\n",with:" ").replacingOccurrences(of:"\n",with:" ")}
        func L(_ k:String)->String{
            guard let custom=labels?[k]?.trimmingCharacters(in:.whitespacesAndNewlines),
                  !custom.isEmpty else{return Self.defaultFrontmatterLabel(for:k)}
            return custom
        }
        let dt=useTT && content.titleTranslated?.isEmpty==false ? content.titleTranslated! : content.title
        var md="---\n"; if fields.contains("id"){md+="\(L("id")): \(content.id)\n"}; if fields.contains("title"){md+="\(L("title")): \"\(y(dt))\"\n"}; if fields.contains("source"){md+="\(L("source")): \"\(y(content.source))\"\n"}; if fields.contains("author"),!content.author.isEmpty{md+="\(L("author")): \"\(y(content.author))\"\n"}; if fields.contains("url"),!content.url.isEmpty{md+="\(L("url")): \"\(y(content.url))\"\n"}; if fields.contains("summary"),!sum.isEmpty{md+="\(L("summary")): \"\(y(sum))\"\n"}; if fields.contains("score"),let s=content.score{md+="\(L("score")): \(s)\n"}; if fields.contains("published"),!content.publishedAt.isEmpty{md+="\(L("published")): \"\(content.publishedAt)\"\n"}; if fields.contains("ctype"){md+="\(L("ctype")): \"\(content.ctype)\"\n"}; if fields.contains("language"),!content.language.isEmpty{md+="\(L("language")): \"\(content.language)\"\n"}; if fields.contains("artifact"){md+="\(L("artifact")): \"\(view)\"\n"}; md+="---\n\n# \(dt)\n\n\(Self.stripLeadingFrontmatter(body))"; if !content.url.isEmpty{md+="\n\n[原文链接](\(content.url))\n"}; return md
    }

    private func writeMD(md: String, content: EC, vaultRoot: String, subTpl: String, fileTpl: String, writePolicy: String, useTranslatedTitle: Bool = false) -> (Bool,String?,String?) {
        do{var dest=try destURL(content:content,vaultRoot:vaultRoot,subTpl:subTpl,fileTpl:fileTpl,useTranslatedTitle:useTranslatedTitle); try FileManager.default.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true); if FileManager.default.fileExists(atPath:dest.path){switch writePolicy{case "skip":return(true,dest.path,nil); case "versioned":let s=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-").prefix(19);dest=dest.deletingLastPathComponent().appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent)-\(s).md"); default:break}}; try Data(md.utf8).write(to:dest,options:[.atomic]); return(true,dest.path,nil)}catch{return(false,nil,error.localizedDescription)}
    }
    private enum ExportPathError: LocalizedError {
        case invalidRoot
        case unsafeComponent(String)
        case unsafeFilename
        case escapedRoot

        var errorDescription: String? {
            switch self {
            case .invalidRoot:
                return "导出根目录无效"
            case .unsafeComponent(let component):
                return "不安全的导出路径：目录中不能包含 \(component)"
            case .unsafeFilename:
                return "不安全的导出路径：文件名不能包含路径分隔符"
            case .escapedRoot:
                return "不安全的导出路径：目标文件超出配置的导出目录"
            }
        }
    }

    private func destURL(content: EC, vaultRoot: String, subTpl: String, fileTpl: String, useTranslatedTitle: Bool = false) throws -> URL {
        let root=URL(fileURLWithPath:vaultRoot,isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix("/") else{throw ExportPathError.invalidRoot}
        var dir=root
        for raw in Self.renderTpl(subTpl,content:content,useTranslatedTitle:useTranslatedTitle).split(separator:"/",omittingEmptySubsequences:true){
            let component=String(raw).trimmingCharacters(in:.whitespaces)
            guard component != ".", component != ".." else{throw ExportPathError.unsafeComponent(component)}
            dir.appendPathComponent(Self.sanitizeFilename(component),isDirectory:true)
        }
        let filename=Self.renderTpl(fileTpl.isEmpty ? "{title}-{id}":fileTpl,content:content,useTranslatedTitle:useTranslatedTitle)
        guard !filename.contains("/") && !filename.contains("\\") else{throw ExportPathError.unsafeFilename}
        let result=dir.appendingPathComponent(Self.sanitizeFilename(filename)+".md").standardizedFileURL
        guard result.path.hasPrefix(root.path+"/")||result.path==root.path else{throw ExportPathError.escapedRoot}
        return result
    }
    private static func renderTpl(_ t: String, content: EC, useTranslatedTitle: Bool = false) -> String {
        var r=t; let d=templateDate(from:content.publishedAt) ?? Date()
        let df=DateFormatter();df.dateFormat="yyyy-MM-dd";let yf=DateFormatter();yf.dateFormat="yyyy";let mf=DateFormatter();mf.dateFormat="MM"
        for (k,v) in ["{id}":String(content.id),"{title}":sanitizeFilename(useTranslatedTitle && content.titleTranslated?.isEmpty == false ? content.titleTranslated! : content.title),"{source}":sanitizeFilename(content.source),"{author}":sanitizeFilename(content.author),"{ctype}":content.ctype,"{score}":content.score.map(String.init) ?? "unscored","{date}":df.string(from:d),"{year}":yf.string(from:d),"{month}":mf.string(from:d)]{r=r.replacingOccurrences(of:k,with:v)}; return r
    }
    private static func templateDate(from value:String)->Date? {
        let trimmed=value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else{return nil}
        if let date=ISO8601DateFormatter().date(from:trimmed){return date}
        let formatter=DateFormatter();formatter.calendar=Calendar(identifier:.gregorian);formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0)
        for format in ["yyyy-MM-dd HH:mm:ss","yyyy-MM-dd"]{
            formatter.dateFormat=format
            if let date=formatter.date(from:trimmed){return date}
        }
        return nil
    }

    private static let dfFields=["title","source","author","url","score","published","id"]
    private static let defaultFrontmatterLabels=["id":"readboard_id","artifact":"artifact_type"]
    static func defaultFrontmatterLabel(for field:String)->String{defaultFrontmatterLabels[field] ?? field}
    private static func calendarDay(from value: String) -> String? {
        let day = String(value.prefix(10))
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return day
    }
    private static func dayAfter(_ value: String) -> String? {
        guard let day = calendarDay(from: value) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day),
              let next = formatter.calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return formatter.string(from: next)
    }
    private static func encodeSA(_ v:[String])->String{(try? JSONSerialization.data(withJSONObject:v,options:[.sortedKeys])).flatMap{String(data:$0,encoding:.utf8)} ?? "[]"}
    private static func decodeSA(_ j:String?)->[String]?{guard let j,let v=try? JSONSerialization.jsonObject(with:Data(j.utf8)) as? [String] else{return nil};return v}
    private func platformIsEnabled(_ target: String) -> Bool {
        switch target {
        case "obsidian", "webhook":
            return ExportPlatformConfig.shared.isEnabled(target)
        case "mddir":
            return true // 兼容开发期和隔离测试创建的旧 Markdown 目录规则。
        default:
            return false
        }
    }
    private func platformDisabledMessage(_ target: String) -> String {
        switch target {
        case "obsidian": return "Obsidian 平台未启用"
        case "webhook": return "Webhook 平台未启用"
        default: return "不支持的导出平台：\(target)"
        }
    }
    private func deliveryConfigurationIssue(for rule: ExportRule) -> String? {
        guard platformIsEnabled(rule.target) else { return platformDisabledMessage(rule.target) }
        switch rule.target {
        case "obsidian":
            return ExportPlatformConfig.shared.obsidianDir.isEmpty ? "Obsidian Vault 未配置" : nil
        case "mddir":
            return (rule.targetConfig["dir"] as? String ?? "").isEmpty ? "目录未配置" : nil
        case "webhook":
            let endpoint = ExportPlatformConfig.shared.webhookURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"), url.host != nil else {
                return "Webhook URL 无效"
            }
            return nil
        default:
            return "不支持的导出平台：\(rule.target)"
        }
    }
    private func deliveryHash(markdown: String, rule: ExportRule) -> String {
        guard rule.target == "webhook" else { return Self.sha256(markdown) }
        let config = ExportPlatformConfig.shared
        let headers = config.webhookHeaders.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\($0.key):\($0.value)" }.joined(separator: "\n")
        // Endpoint 或鉴权 Header 变化后必须重新投递，不能被旧渲染哈希挡住。
        return Self.sha256([markdown, config.webhookURL, headers].joined(separator: "\u{1f}"))
    }
    private func currentWebhookSession() -> URLSession {
        webhookSessionLock.lock(); defer { webhookSessionLock.unlock() }
        return webhookSession
    }
    private func deliveryFP(_ rule: ExportRule) -> String { let cfg=(try? JSONSerialization.data(withJSONObject:rule.targetConfig,options:[.sortedKeys])).flatMap{String(data:$0,encoding:.utf8)} ?? "{}"; return[rule.criteria.toJSON(),ExportRule.normalizedTrigger(rule.triggerOn),rule.target,cfg,rule.effectiveArtifact,rule.missingPolicy,rule.outputFormat,rule.effectiveSubfolderTemplate,rule.titleTemplate,rule.effectiveWritePolicy,rule.historyScope,Self.encodeSA(rule.frontmatterFields ?? Self.dfFields),rule.attachmentsPolicy].joined(separator:"\u{1f}") }
    private func beginRR(_ id:Int64)->Bool{guard id>0 else{return true};rLock.lock();defer{rLock.unlock()};return rIds.insert(id).inserted}
    private func endRR(_ id:Int64){guard id>0 else{return};rLock.lock();rIds.remove(id);rLock.unlock()}
    private func isDue(_ rule: ExportRule)->Bool{guard let last=rule.lastRunAt,!last.isEmpty else{return true};let f=DateFormatter();f.dateFormat="yyyy-MM-dd HH:mm:ss";f.timeZone=TimeZone(secondsFromGMT:0);guard let d=f.date(from:last) else{return true};let freq=rule.targetConfig["schedule_interval"] as? String ?? "daily";let interval:TimeInterval=freq=="hourly" ? 3600 : freq=="weekly" ? 604800 : 86400;return Date().timeIntervalSince(d) >= interval}
    private static func sha256(_ t:String)->String{SHA256.hash(data:Data(t.utf8)).map{String(format:"%02x",$0)}.joined()}
}

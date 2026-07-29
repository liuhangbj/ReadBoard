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
    private init() {}

    func listRules() -> [ExportRule] { db.queryRows("SELECT id,name,enabled,criteria,trigger_on,target,target_config,last_run_at,revision,artifact,missing_policy,output_format,subfolder_template,filename_template,write_policy,history_scope,frontmatter_fields,attachments_policy,created_at FROM export_rule ORDER BY id").map{r in var rule=ExportRule(id:Int64(r["id"] ?? "") ?? 0,name:r["name"] ?? "未命名",enabled:r["enabled"]=="1",criteria:ExportRule.Criteria.from(json:r["criteria"] ?? "{}"),triggerOn:ExportRule.normalizedTrigger(r["trigger_on"] ?? "manual"),target:r["target"] ?? "mddir",targetConfig:((try? JSONSerialization.jsonObject(with:Data((r["target_config"] ?? "{}").utf8))) as? [String:Any]) ?? [:],lastRunAt:r["last_run_at"]); rule.revision=Int(r["revision"] ?? "") ?? 1; rule.artifact=r["artifact"] ?? "original"; rule.missingPolicy=r["missing_policy"] ?? "wait"; rule.outputFormat=r["output_format"] ?? "markdown"; rule.subfolderTemplate=r["subfolder_template"] ?? ""; rule.titleTemplate=r["filename_template"] ?? "{title}-{id}"; rule.writePolicy=r["write_policy"] ?? "overwrite"; rule.overwrite=rule.writePolicy=="overwrite"; rule.historyScope=r["history_scope"] ?? "all"; rule.frontmatterFields=Self.decodeSA(r["frontmatter_fields"]); rule.attachmentsPolicy=r["attachments_policy"] ?? "remote"; rule.createdAt=r["created_at"]; rule.useTranslatedTitle=rule.targetConfig["use_translated_title"] as? Bool ?? false; rule.frontmatterLabels=rule.targetConfig["frontmatter_labels"] as? [String:String]; return rule } }

    @discardableResult func saveRule(_ rule: ExportRule) -> Int64 {
        var n=rule; n.triggerOn=ExportRule.normalizedTrigger(rule.triggerOn); n.artifact=rule.effectiveArtifact; n.subfolderTemplate=rule.effectiveSubfolderTemplate; n.writePolicy=rule.effectiveWritePolicy
        n.targetConfig["view"]=n.artifact; n.targetConfig["subfolder"]=n.subfolderTemplate; n.targetConfig["overwrite"]=n.writePolicy=="overwrite"
        n.targetConfig["use_translated_title"]=rule.useTranslatedTitle; if let l=rule.frontmatterLabels{n.targetConfig["frontmatter_labels"]=l}
        let cj=(try? JSONSerialization.data(withJSONObject:n.targetConfig,options:[.sortedKeys])).flatMap{String(data:$0,encoding:.utf8)} ?? "{}"
        let fj=Self.encodeSA(n.frontmatterFields ?? Self.dfFields); let cur=rule.id>0 ? listRules().first{$0.id==rule.id} : nil
        if rule.id>0 { let rev=(cur.map{deliveryFP($0) != deliveryFP(n)} ?? false) ? max(1,(cur?.revision ?? 1)+1) : max(1,cur?.revision ?? n.revision)
            db.execute("UPDATE export_rule SET name=?,enabled=?,criteria=?,trigger_on=?,target=?,target_config=?,revision=?,artifact=?,missing_policy=?,output_format=?,subfolder_template=?,filename_template=?,write_policy=?,history_scope=?,frontmatter_fields=?,attachments_policy=? WHERE id=?",params:[n.name,n.enabled ? 1:0,n.criteria.toJSON(),n.triggerOn,n.target,cj,rev,n.artifact,n.missingPolicy,n.outputFormat,n.subfolderTemplate,n.titleTemplate,n.writePolicy,n.historyScope,fj,n.attachmentsPolicy,n.id]); return rule.id }
        db.execute("INSERT INTO export_rule(name,enabled,criteria,trigger_on,target,target_config,revision,artifact,missing_policy,output_format,subfolder_template,filename_template,write_policy,history_scope,frontmatter_fields,attachments_policy)VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",params:[n.name,n.enabled ? 1:0,n.criteria.toJSON(),n.triggerOn,n.target,cj,max(1,n.revision),n.artifact,n.missingPolicy,n.outputFormat,n.subfolderTemplate,n.titleTemplate,n.writePolicy,n.historyScope,fj,n.attachmentsPolicy]); return db.lastInsertId() }
    func deleteRule(id: Int64) { db.execute("DELETE FROM export_rule WHERE id=?",params:[id]) }
    func resetDelivered(ruleId: Int64) { db.execute("UPDATE export_rule SET revision=revision+1 WHERE id=?",params:[ruleId]) }
    func statsFor(ruleId: Int64) -> (delivered:Int,failed:Int) { let d=db.scalarInt("SELECT COUNT(*) FROM export_record WHERE rule_id=? AND status='delivered'",params:[ruleId]) ?? 0; let f=db.scalarInt("SELECT COUNT(*) FROM export_record WHERE rule_id=? AND status='failed'",params:[ruleId]) ?? 0; return (d,f) }

    func runPending(trigger: String, contentId: Int64?=nil) async { guard FeatureBoard.export.enabled else {return}; let nt=ExportRule.normalizedTrigger(trigger); for rule in listRules() where rule.enabled && ExportRule.normalizedTrigger(rule.triggerOn)==nt { if nt=="scheduled",!isDue(rule){continue}; await run(rule:rule,contentId:contentId)} }
    func runFor(ruleId: Int64) async { guard let rule=listRules().first(where:{$0.id==ruleId}) else {return}; await run(rule:rule,contentId:nil) }
    func startScheduler(intervalSeconds: TimeInterval=300) { sLock.lock();defer{sLock.unlock()}; guard sTask==nil else{return}; sTask=Task{[weak self] in do{try await Task.sleep(nanoseconds:5_000_000_000)}catch{return}; while !Task.isCancelled{guard !Task.isCancelled,let self else{break}; await self.runPending(trigger:"scheduled"); do{try await Task.sleep(nanoseconds:UInt64(max(30,intervalSeconds)*1_000_000_000))}catch{break}} } }
    func stopScheduler() { sLock.lock();let t=sTask;sTask=nil;sLock.unlock();t?.cancel() }

    func preview(rule: ExportRule, maxSamples: Int=3) -> ExportRulePreview {
        var bid:Int64?; var cnt=0; var ss:[ExportRulePreview.Sample]=[]; let fields=rule.frontmatterFields ?? Self.dfFields; let labels=rule.frontmatterLabels; let utt=rule.useTranslatedTitle
        repeat{let page=matching(rule:rule,contentId:nil,beforeId:bid); guard !page.isEmpty else{break}; cnt+=page.count; for c in page where ss.count<max(0,maxSamples){var md=renderMD(content:c,view:rule.effectiveArtifact,fields:fields,labels:labels,useTT:utt); if md==nil && rule.missingPolicy=="fallback_original"{md=renderMD(content:c,view:"original",fields:fields,labels:labels,useTT:utt)}; var dest:String?; var issue:String?; if md==nil{issue="缺少文稿"} else if rule.target=="obsidian"||rule.target=="mddir"{let root=rule.targetConfig["dir"] as? String ?? ExportPlatformConfig.shared.obsidianDir; if root.isEmpty{issue="目录未配置"} else{do{dest=try destURL(content:c,vaultRoot:root,subTpl:rule.effectiveSubfolderTemplate,fileTpl:rule.titleTemplate).path}catch{issue=error.localizedDescription}}}; ss.append(.init(contentId:c.id,title:c.title,markdown:md,destination:dest,issue:issue))}; bid=page.last?.id}while bid != nil; return ExportRulePreview(matchingCount:cnt,samples:ss) }

    func deliverSingle(rule: ExportRule, contentId: Int64) async -> (Bool,String?,String?) { guard let c=loadEC(id:contentId) else{return (false,nil,"内容不存在")}; let r=await deliver(rule:rule,c:c); return (r.status=="delivered"||r.status=="skipped",r.destination,r.error) }
    func renderForExport(contentId: Int64, view: String) -> String? { guard let c=loadEC(id:contentId) else{return nil}; return renderMD(content:c,view:view,fields:Self.dfFields) }
    static func sanitizeFilename(_ name:String) -> String { var s=name.replacingOccurrences(of:"[/\\\\:\\*\\?\"<>\\|]",with:"",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines); if s.isEmpty{s="untitled"}; if s.count>180{s=String(s.prefix(180))}; return s }
    static func stripLeadingFrontmatter(_ text:String) -> String { let t=text.trimmingCharacters(in:.whitespacesAndNewlines); guard t.hasPrefix("---") else{return text}; var lines=t.components(separatedBy:"\n"); guard lines.count>2 else{return text}; lines.removeFirst(); if let end=lines.firstIndex(where:{$0.trimmingCharacters(in:.whitespaces)=="---"}){return lines[(end+1)...].joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)}; return text }

    #if DEBUG
    func scheduledRuleIsDueForTesting(_ rule: ExportRule, now: Date) -> Bool { guard let last=rule.lastRunAt,!last.isEmpty else{return true}; let f=DateFormatter();f.dateFormat="yyyy-MM-dd HH:mm:ss";f.timeZone=TimeZone(secondsFromGMT:0); guard let d=f.date(from:last) else{return true}; let freq=rule.targetConfig["schedule_interval"] as? String ?? "daily"; let interval:TimeInterval = freq=="hourly" ? 3600 : freq=="weekly" ? 604800 : 86400; return now.timeIntervalSince(d) >= interval }
    #endif

    // MARK: internal
    private func run(rule: ExportRule, contentId: Int64?) async { guard beginRR(rule.id) else{return};defer{endRR(rule.id)}; var bid:Int64?;var tot=0; while tot<2000{let candidates=matching(rule:rule,contentId:contentId,beforeId:bid); guard !candidates.isEmpty else{break}; for c in candidates{let result=await deliver(rule:rule,c:c); db.execute("INSERT INTO export_record(rule_id,content_id,artifact,revision,status,destination,error,rendered_hash,attempts,updated_at)VALUES(?,?,?,?,?,?,?,?,?,datetime('now'))ON CONFLICT(rule_id,content_id,artifact,revision)DO UPDATE SET status=excluded.status,destination=COALESCE(excluded.destination,export_record.destination),error=excluded.error,rendered_hash=COALESCE(excluded.rendered_hash,export_record.rendered_hash),attempts=export_record.attempts+excluded.attempts,updated_at=datetime('now')",params:[rule.id,c.id,rule.effectiveArtifact,rule.revision,result.status,result.destination,result.error,result.renderedHash,result.didAttempt ? 1:0])}; bid=candidates.last?.id;tot+=candidates.count}; db.execute("UPDATE export_rule SET last_run_at=datetime('now') WHERE id=?",params:[rule.id]) }

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
        if let a=rule.criteria.publishedAfter,!a.isEmpty{w.append("published_at>=?");p.append(a)}; if let b=rule.criteria.publishedBefore,!b.isEmpty{w.append("published_at<=?");p.append(b)}
        if rule.historyScope=="new_only"{let ca=rule.createdAt?.isEmpty==false ? rule.createdAt! : ISO8601DateFormatter().string(from:Date()); w.append("created_at>=?");p.append(ca)}
        let sql="SELECT id,title,url,source,author,llm_score,llm_summary,llm_translated_md,llm_transcript_md,content_md,excerpt,published_at,ctype,language,llm_title_translated FROM content WHERE \(w.joined(separator:" AND ")) ORDER BY id DESC LIMIT 200"
        return db.queryRows(sql,params:p).map{r in EC(id:Int64(r["id"] ?? "") ?? 0,title:r["title"] ?? "",url:r["url"] ?? "",source:r["source"] ?? "",author:r["author"] ?? "",ctype:r["ctype"] ?? "article",language:r["language"] ?? "",score:Int(r["llm_score"] ?? ""),summary:r["llm_summary"],translated:r["llm_translated_md"],transcript:r["llm_transcript_md"],contentMd:r["content_md"],excerpt:r["excerpt"],titleTranslated:r["llm_title_translated"],publishedAt:r["published_at"] ?? "")}
    }

    private struct EC { let id:Int64;let title,url,source,author:String;let ctype,language:String;let score:Int?;let summary,translated,transcript,contentMd,excerpt:String?;let titleTranslated:String?;let publishedAt:String }
    private func loadEC(id: Int64) -> EC? { guard let r=db.queryRows("SELECT id,title,url,source,author,llm_score,llm_summary,llm_translated_md,llm_transcript_md,content_md,excerpt,published_at,ctype,language,llm_title_translated FROM content WHERE id=?",params:[id]).first else{return nil}; return EC(id:Int64(r["id"] ?? "") ?? 0,title:r["title"] ?? "",url:r["url"] ?? "",source:r["source"] ?? "",author:r["author"] ?? "",ctype:r["ctype"] ?? "article",language:r["language"] ?? "",score:Int(r["llm_score"] ?? ""),summary:r["llm_summary"],translated:r["llm_translated_md"],transcript:r["llm_transcript_md"],contentMd:r["content_md"],excerpt:r["excerpt"],titleTranslated:r["llm_title_translated"],publishedAt:r["published_at"] ?? "") }
    private struct DR { let status:String;let destination:String?;let error:String?;let renderedHash:String?;let didAttempt:Bool }

    private func deliver(rule: ExportRule, c: EC) async -> DR {
        let artifact=rule.effectiveArtifact;let fields=rule.frontmatterFields ?? Self.dfFields;let labels=rule.frontmatterLabels;let utt=rule.useTranslatedTitle
        var md=renderMD(content:c,view:artifact,fields:fields,labels:labels,useTT:utt); if md==nil && rule.missingPolicy=="fallback_original"{md=renderMD(content:c,view:"original",fields:fields,labels:labels,useTT:utt)}
        guard let md else{let st=rule.missingPolicy=="skip" ? "skipped":"waiting";return DR(status:st,destination:nil,error:"缺少文稿",renderedHash:nil,didAttempt:false)}
        let hash=Self.sha256(md); if rule.id>0,let _=db.queryRows("SELECT destination FROM export_record WHERE rule_id=? AND content_id=? AND artifact=? AND revision=? AND status='delivered' AND rendered_hash=? LIMIT 1",params:[rule.id,c.id,artifact,rule.revision,hash]).first{return DR(status:"delivered",destination:nil,error:nil,renderedHash:hash,didAttempt:false)}
        let dir=(rule.targetConfig["dir"] as? String) ?? (rule.target=="obsidian" ? ExportPlatformConfig.shared.obsidianDir : "")
        guard !dir.isEmpty else{return DR(status:"failed",destination:nil,error:"目录未配置",renderedHash:hash,didAttempt:false)}
        let t=writeMD(md:md,content:c,vaultRoot:dir,subTpl:rule.effectiveSubfolderTemplate,fileTpl:rule.titleTemplate,writePolicy:rule.effectiveWritePolicy)
        return DR(status:t.0 ? "delivered":"failed",destination:t.1,error:t.2,renderedHash:hash,didAttempt:true)
    }

    private func renderMD(content: EC, view: String, fields: [String], labels: [String:String]?=nil, useTT: Bool=false) -> String? {
        let orig=[content.contentMd,content.excerpt].compactMap{$0?.trimmingCharacters(in:.whitespacesAndNewlines)}.first{!$0.isEmpty} ?? ""
        let trans=content.translated?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""; let trscr=content.transcript?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let sum=content.summary?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let body: String; switch view{case "translated":guard !trans.isEmpty else{return nil};body=trans; case "transcript":guard !trscr.isEmpty else{return nil};body=trscr; case "summary":guard !sum.isEmpty else{return nil};body=sum; case "summary_original":guard !sum.isEmpty,!orig.isEmpty else{return nil};body="## 摘要\n\n\(sum)\n\n## 原文\n\n\(orig)"; case "summary_translated":guard !sum.isEmpty,!trans.isEmpty else{return nil};body="## 摘要\n\n\(sum)\n\n## 译文\n\n\(trans)"; case "summary_transcript":guard !sum.isEmpty,!trscr.isEmpty else{return nil};body="## 摘要\n\n\(sum)\n\n## 转录稿\n\n\(trscr)"; default:guard !orig.isEmpty else{return nil};body=orig}
        func y(_ v:String)->String{v.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\r\n",with:" ").replacingOccurrences(of:"\n",with:" ")}
        func L(_ k:String)->String{labels?[k] ?? k}
        let dt=useTT && content.titleTranslated?.isEmpty==false ? content.titleTranslated! : content.title
        var md="---\n"; if fields.contains("id"){md+="\(L("id")): \(content.id)\n"}; if fields.contains("title"){md+="\(L("title")): \"\(y(dt))\"\n"}; if fields.contains("source"){md+="\(L("source")): \"\(y(content.source))\"\n"}; if fields.contains("author"),!content.author.isEmpty{md+="\(L("author")): \"\(y(content.author))\"\n"}; if fields.contains("url"),!content.url.isEmpty{md+="\(L("url")): \"\(y(content.url))\"\n"}; if fields.contains("summary"),!sum.isEmpty{md+="\(L("summary")): \"\(y(sum))\"\n"}; if fields.contains("score"),let s=content.score{md+="\(L("score")): \(s)\n"}; if fields.contains("published"),!content.publishedAt.isEmpty{md+="\(L("published")): \"\(content.publishedAt)\"\n"}; if fields.contains("ctype"){md+="\(L("ctype")): \"\(content.ctype)\"\n"}; if fields.contains("language"),!content.language.isEmpty{md+="\(L("language")): \"\(content.language)\"\n"}; if fields.contains("artifact"){md+="\(L("artifact")): \"\(view)\"\n"}; md+="---\n\n# \(dt)\n\n\(Self.stripLeadingFrontmatter(body))"; if !content.url.isEmpty{md+="\n\n[原文链接](\(content.url))\n"}; return md
    }

    private func writeMD(md: String, content: EC, vaultRoot: String, subTpl: String, fileTpl: String, writePolicy: String) -> (Bool,String?,String?) {
        do{var dest=try destURL(content:content,vaultRoot:vaultRoot,subTpl:subTpl,fileTpl:fileTpl); try FileManager.default.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true); if FileManager.default.fileExists(atPath:dest.path){switch writePolicy{case "skip":return(true,dest.path,nil); case "versioned":let s=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-").prefix(19);dest=dest.deletingLastPathComponent().appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent)-\(s).md"); default:break}}; try Data(md.utf8).write(to:dest,options:[.atomic]); return(true,dest.path,nil)}catch{return(false,nil,error.localizedDescription)}
    }
    private func destURL(content: EC, vaultRoot: String, subTpl: String, fileTpl: String) throws -> URL {
        let root=URL(fileURLWithPath:vaultRoot,isDirectory:true).standardizedFileURL.resolvingSymlinksInPath(); guard root.path.hasPrefix("/") else{throw NSError(domain:"export",code:1)}
        var dir=root; for raw in Self.renderTpl(subTpl,content:content).split(separator:"/",omittingEmptySubsequences:true){let c=String(raw).trimmingCharacters(in:.whitespaces); guard c != ".", c != ".." else{throw NSError(domain:"export",code:2)}; dir.appendPathComponent(Self.sanitizeFilename(c),isDirectory:true)}
        let fn=Self.renderTpl(fileTpl.isEmpty ? "{title}-{id}":fileTpl,content:content); guard !fn.contains("/") && !fn.contains("\\") else{throw NSError(domain:"export",code:2)}
        let result=dir.appendingPathComponent(Self.sanitizeFilename(fn)+".md").standardizedFileURL; guard result.path.hasPrefix(root.path+"/")||result.path==root.path else{throw NSError(domain:"export",code:2)}; return result
    }
    private static func renderTpl(_ t: String, content: EC) -> String {
        var r=t; let d=content.publishedAt.isEmpty ? Date() : ISO8601DateFormatter().date(from:content.publishedAt) ?? Date()
        let df=DateFormatter();df.dateFormat="yyyy-MM-dd";let yf=DateFormatter();yf.dateFormat="yyyy";let mf=DateFormatter();mf.dateFormat="MM"
        for (k,v) in ["{id}":String(content.id),"{title}":sanitizeFilename(content.title),"{source}":sanitizeFilename(content.source),"{author}":sanitizeFilename(content.author),"{ctype}":content.ctype,"{score}":content.score.map(String.init) ?? "unscored","{date}":df.string(from:d),"{year}":yf.string(from:d),"{month}":mf.string(from:d)]{r=r.replacingOccurrences(of:k,with:v)}; return r
    }

    private static let dfFields=["title","source","author","url","score","published","id"]
    private static func encodeSA(_ v:[String])->String{(try? JSONSerialization.data(withJSONObject:v,options:[.sortedKeys])).flatMap{String(data:$0,encoding:.utf8)} ?? "[]"}
    private static func decodeSA(_ j:String?)->[String]?{guard let j,let v=try? JSONSerialization.jsonObject(with:Data(j.utf8)) as? [String] else{return nil};return v}
    private func deliveryFP(_ rule: ExportRule) -> String { let cfg=(try? JSONSerialization.data(withJSONObject:rule.targetConfig,options:[.sortedKeys])).flatMap{String(data:$0,encoding:.utf8)} ?? "{}"; return[rule.criteria.toJSON(),ExportRule.normalizedTrigger(rule.triggerOn),rule.target,cfg,rule.effectiveArtifact,rule.missingPolicy,rule.outputFormat,rule.effectiveSubfolderTemplate,rule.titleTemplate,rule.effectiveWritePolicy,rule.historyScope,Self.encodeSA(rule.frontmatterFields ?? Self.dfFields),rule.attachmentsPolicy].joined(separator:"\u{1f}") }
    private func beginRR(_ id:Int64)->Bool{guard id>0 else{return true};rLock.lock();defer{rLock.unlock()};return rIds.insert(id).inserted}
    private func endRR(_ id:Int64){guard id>0 else{return};rLock.lock();rIds.remove(id);rLock.unlock()}
    private func isDue(_ rule: ExportRule)->Bool{guard let last=rule.lastRunAt,!last.isEmpty else{return true};let f=DateFormatter();f.dateFormat="yyyy-MM-dd HH:mm:ss";f.timeZone=TimeZone(secondsFromGMT:0);guard let d=f.date(from:last) else{return true};let freq=rule.targetConfig["schedule_interval"] as? String ?? "daily";let interval:TimeInterval=freq=="hourly" ? 3600 : freq=="weekly" ? 604800 : 86400;return Date().timeIntervalSince(d) >= interval}
    private static func sha256(_ t:String)->String{SHA256.hash(data:Data(t.utf8)).map{String(format:"%02x",$0)}.joined()}
}

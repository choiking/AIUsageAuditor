import Foundation
import AuditorCore

/// Every piece of interface copy, in both languages, in one table. Views read
/// from here rather than holding literals so that a translation can be checked
/// for completeness without reading the layout code.
struct Copy {
    let language: AppLanguage
    private func t(_ chinese: String, _ english: String) -> String { language.pick(chinese, english) }
    private var chinese: Bool { language.resolved == .chinese }
    /// English nouns have to agree with their count; Chinese ones do not, so
    /// this is only ever called from the English half of a pair.
    private func n(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) " + (value == 1 ? singular : plural)
    }

    // MARK: Chrome

    /// The product is 码表 — a pun on the everyday word for a speedometer, with
    /// 码 for code. English keeps the romanization-free original.
    var appName: String { t("码表", "Agent Meter") }
    var windowTitle: String { t("码表 · 日志", "Agent Meter · Logs") }
    var previewTitle: String { t("码表 · 预览", "Agent Meter · Preview") }
    var subtitle: String { t("LOG USAGE  ·  日志上报用量", "LOG USAGE  ·  REPORTED TOKENS") }
    var languageMenu: String { t("语言", "Language") }
    var period: String { t("统计期间", "Period") }
    var history: String { t("历史", "History") }
    func periodName(_ period: LogPeriod) -> String {
        switch period {
        case .today: return t("今日", "Today")
        case .all: return t("已导入历史", "Imported history")
        }
    }
    func tabName(_ tab: AuditorTab) -> String {
        switch tab {
        case .usage: return t("用量", "Usage")
        case .analysis: return t("分析", "Analysis")
        }
    }
    func tabCaption(_ tab: AuditorTab) -> String {
        switch tab {
        case .usage: return t("token 计数与目录价估算", "Token counts and list-price estimate")
        case .analysis: return t("prompt 内容索引与分类", "Prompt index and categories")
        }
    }
    func menuBarLabel(input: Int64, output: Int64) -> String {
        t("今日日志上报 token：输入 \(input)，输出 \(output)",
          "Log-reported tokens today: input \(input), output \(output)")
    }

    // MARK: Usage page

    func totalsHeading(_ period: LogPeriod) -> String {
        period == .today ? t("今日 · 全部日志来源", "Today · all log sources")
                         : t("已导入历史 · 全部来源", "Imported history · all sources")
    }
    func recordSummary(records: Int, total: Int64) -> String {
        t("\(records.formatted()) 条去重用量记录 · 总计 \(total.formatted()) tokens",
          "\(n(records, "deduplicated usage record", "deduplicated usage records")) · \(total.formatted()) tokens total")
    }
    var byToolHeading: String { t("按工具与日志入口分类", "By tool and log entrypoint") }
    func entryCount(_ count: Int) -> String { t("\(count) 项", n(count, "entry", "entries")) }
    var noCountableUsage: String { t("当前期间暂无可计入的日志用量", "No countable log usage in this period") }
    var noRecordsFound: String { t("未发现用量记录", "No usage records found") }
    func rowTotals(_ totals: LogTotals) -> String {
        t("↑ \(totals.input.formatted())   ↓ \(totals.output.formatted())   · \(totals.records) 条",
          "↑ \(totals.input.formatted())   ↓ \(totals.output.formatted())   · \(n(totals.records, "record", "records"))")
    }
    var noProvenance: String { t("未发现记录", "no records found") }
    func lastUsage(_ date: String) -> String { t("最近用量记录：\(date)", "Latest usage record: \(date)") }
    var emptyPeriodNote: String {
        t("当前统计期间没有可计入记录；不代表账号实际消耗为零。",
          "No records fall in this period; that does not mean the account consumed nothing.")
    }

    // MARK: Token breakdown

    var uncachedInput: String { t("未缓存输入", "Uncached input") }
    var cacheRead: String { t("缓存读取", "Cache read") }
    var cacheWrite: String { t("缓存写入", "Cache write") }
    var ttl1h: String { t("· 1 小时 TTL", "· 1-hour TTL") }
    var ttl5m: String { t("· 5 分钟 TTL", "· 5-minute TTL") }
    var output: String { t("输出", "Output") }
    var input: String { t("输入", "Input") }
    var ofWhichCacheRead: String { t("· 其中缓存读取", "· of which cache read") }
    var ofWhichCacheWrite: String { t("· 其中缓存写入", "· of which cache write") }
    var ofWhichReasoning: String { t("· 其中推理", "· of which reasoning") }
    var total: String { t("合计", "Total") }
    var claudeBreakdownNote: String {
        t("前三项相加即为 INPUT；两种 TTL 相加即为缓存写入。",
          "The first three add up to INPUT; the two TTLs add up to cache write.")
    }
    var codexBreakdownNote: String {
        t("缓存与推理是输入 / 输出的细分，已包含在内，不要重复相加。数值为相邻累计计数之差。",
          "Cache and reasoning are breakdowns of input / output and are already counted in them — do not add them again. Values are differences between consecutive cumulative counts.")
    }
    func partiallyKnown(_ value: Int64) -> String {
        t("已知 \(value.formatted()) · 部分未上报", "\(value.formatted()) known · some not reported")
    }

    // MARK: Cost

    var costTitle: String { t("API 目录价估算", "API list-price estimate") }
    var costNote: String {
        t("按公开 API 单价折算，非账单、非订阅扣费。订阅用户按月付费，与此数字无关。",
          "Converted at published API rates; not a bill and not a subscription charge. Subscribers pay a flat monthly fee regardless of this number.")
    }
    var noPriceableRecords: String { t("当前来源无可定价记录", "No priceable records for this source") }
    func unpricedNote(_ cost: CostEstimate) -> String {
        var parts: [String] = []
        if cost.unpricedRecords > 0 {
            let models = cost.unpricedModels.sorted().prefix(3).joined(separator: chinese ? "、" : ", ")
            let more = cost.unpricedModels.count > 3 ? t(" 等", " and others") : ""
            parts.append(t("\(cost.unpricedRecords) 条记录的模型无内置单价（\(models)\(more)），未计入。",
                           "\(n(cost.unpricedRecords, "record uses a model", "records use models")) with no built-in rate (\(models)\(more)); not counted."))
        }
        if cost.unknownModelRecords > 0 {
            parts.append(t("\(cost.unknownModelRecords) 条记录未标明模型，未计入。",
                           "\(n(cost.unknownModelRecords, "record names", "records name")) no model; not counted."))
        }
        if !parts.isEmpty { parts.append(t("可在 pricing.json 中自行补充单价。", "You can add rates yourself in pricing.json.")) }
        return parts.joined(separator: chinese ? "" : " ")
    }

    // MARK: Status and controls

    var scanFailed: String { t("采集失败 · 显示上次成功结果", "Scan failed · showing the last successful result") }
    var demoMode: String { t("演示模式 · 模拟日志数据", "Demo mode · simulated log data") }
    var reading: String { t("正在读取本地日志…", "Reading local logs…") }
    var pausedStatus: String { t("采集已暂停 · 恢复后补读日志", "Paused · logs are re-read on resume") }
    var awaitingFirstImport: String { t("等待首次导入", "Waiting for the first import") }
    var noLogsFound: String { t("未发现日志 · 仅显示已保存历史", "No logs found · showing saved history only") }
    var watching: String { t("日志采集中 · 每 5 秒检查新增记录", "Watching logs · checking for new records every 5s") }
    var readFailed: String { t("日志读取失败。", "Could not read the logs.") }
    func lastChecked(_ time: String, claude: Int, codex: Int) -> String {
        t("最近检查 \(time) · Claude Code \(claude) 个文件 · Codex \(codex) 个文件",
          "Last checked \(time) · Claude Code \(n(claude, "file", "files")) · Codex \(n(codex, "file", "files"))")
    }
    var footerNote: String {
        t("仅统计本机 Claude 编程代理与 Codex 日志，不覆盖普通 Claude / ChatGPT 聊天。输入已含缓存，输出可能含推理，不重复相加；用量不等于订阅额度或账单。",
          "Counts only local Claude coding-agent and Codex logs; regular Claude / ChatGPT chat is not covered. Input already includes cache and output may include reasoning, so do not add them again. Usage is not a subscription quota or a bill.")
    }
    var pause: String { t("暂停采集", "Pause") }
    var resume: String { t("恢复采集", "Resume") }
    var refresh: String { t("刷新", "Refresh") }
    var openLogFolder: String { t("打开来源日志目录", "Open source log folder") }
    var openDataFolder: String { t("打开本地账本目录", "Open local ledger folder") }
    var openWindow: String { t("在独立窗口查看", "Open in a separate window") }
    var quit: String { t("退出", "Quit") }

    // MARK: Warnings

    func excludedSessions(_ count: Int) -> String {
        t("\(count) 个 Codex 会话的计数出现回退，已排除；当前合计不完整。",
          "\(n(count, "Codex session", "Codex sessions")) reported counts going backwards and " +
          (count == 1 ? "was" : "were") + " excluded; the totals are incomplete.")
    }
    func readErrors(_ count: Int) -> String {
        t("\(count) 处日志无法读取，本轮结果可能不完整。",
          "\(n(count, "log", "logs")) could not be read; this round's result may be incomplete.")
    }
    func incompleteUsage(_ usage: Int, ambiguous: Int) -> String {
        t("\(usage) 条用量字段不完整，\(ambiguous) 条消息快照冲突，已跳过。",
          "\(n(usage, "record", "records")) had incomplete usage fields and \(n(ambiguous, "message snapshot", "message snapshots")) conflicted; both were skipped.")
    }
    func invalidLines(_ count: Int) -> String {
        t("已跳过 \(count) 条无效或过长记录。", "Skipped \(n(count, "invalid or oversized record", "invalid or oversized records")).")
    }
    func undatedRecords(_ count: Int) -> String {
        t("\(count) 条历史累计记录无法确定发生日期，仅计入历史合计。",
          "\(n(count, "cumulative history record has", "cumulative history records have")) no determinable date and count only toward the history total.")
    }

    // MARK: Analysis page

    func analysisTitle(_ period: LogPeriod) -> String {
        period == .today ? t("今日内容分析", "Today's content analysis")
                         : t("历史内容分析", "Content analysis of history")
    }
    var analysisCaption: String {
        t("按用户提示词归类 · 本地关键词规则，可能误分",
          "Grouped by user prompt · local keyword rules, may misclassify")
    }
    var sourceApp: String { t("应用来源", "Source app") }
    var allSources: String { t("全部来源", "All sources") }
    var prompts: String { t("提示词", "Prompts") }
    var sessions: String { t("涉及会话", "Sessions") }
    var replies: String { t("AI 回复记录", "AI replies") }
    func stillReading(_ count: Int) -> String {
        t("正在分批读取 \(count) 个日志，当前分类尚不完整。",
          "Still reading \(n(count, "log", "logs")) in batches; this breakdown is incomplete.")
    }
    func analysisSkipped(errors: Int, skipped: Int) -> String {
        t("\(errors) 处读取失败，\(skipped) 条无效或过长记录已跳过。",
          "\(n(errors, "read failure", "read failures")); \(n(skipped, "invalid or oversized record", "invalid or oversized records")) skipped.")
    }
    func noPrompts(_ period: LogPeriod) -> String {
        period == .today ? t("今日未发现可识别的用户提示词，可切换历史查看。",
                             "No recognizable user prompts today; switch to History to look further back.")
                         : t("现存日志中没有可识别的用户提示词。",
                             "No recognizable user prompts in the logs still on this Mac.")
    }
    var categories: String { t("内容分类", "Categories") }
    var allCategories: String { t("全部分类", "All categories") }
    func promptCount(_ count: Int) -> String { t("提示词 · \(count) 条", "Prompts · \(count)") }
    var searchPrompts: String { t("搜索提示词", "Search prompts") }
    var noMatches: String { t("没有匹配的提示词", "No matching prompts") }
    var showMore: String { t("再显示 30 条", "Show 30 more") }
    var truncated: String { t("仅显示前 12,000 字符", "Showing the first 12,000 characters") }
    var toolActivity: String { t("工具活动 · 当前期间与来源", "Tool activity · current period and source") }
    func toolErrors(_ count: Int) -> String {
        t("Claude 明确标记的工具错误：\(count)；Codex 工具错误暂不统计。",
          "Tool errors Claude explicitly flagged: \(count). Codex tool errors are not counted yet.")
    }
    func analysisFooter(_ time: String) -> String {
        t("更新于 \(time)。历史含今日，仅覆盖仍保留在本机的日志。分类占比按提示词条数计算，不代表 token 占比。",
          "Updated \(time). History includes today and covers only logs still on this Mac. Category shares count prompts, not tokens.")
    }
    var analysisDemo: String {
        t("演示模式不读取真实对话；正常启动后可使用内容分析。",
          "Demo mode reads no real conversations; launch normally to use content analysis.")
    }
    var analysisPaused: String {
        t("采集已暂停；恢复采集后读取内容。", "Paused; content is read again after you resume.")
    }
    var analysisFirstRun: String { t("首次分析正在读取本地日志…", "The first analysis is reading local logs…") }
    var analysisPrivacy: String {
        t("提示词仅在内存中分析与展示，不另存、不上传。已过滤已知系统上下文与工具结果；未识别的注入内容仍可能混入。",
          "Prompts are analyzed and shown in memory only — never saved, never uploaded. Known system context and tool results are filtered out; unrecognized injected content may still slip through.")
    }
}

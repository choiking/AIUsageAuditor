import SwiftUI
import AuditorCore

/// Analysis is filtered by tool, not by individual entrypoint: the per-entrypoint
/// split matters for token accounting, not for what was being asked about.
/// Modelled as three explicit cases rather than an optional so that the
/// segmented picker has an unambiguous tag for "all".
enum AnalysisScope: String, CaseIterable, Identifiable {
    case all = "全部来源", claudeCode = "Claude Code", codex = "Codex"
    var id: String { rawValue }
    var tool: LogTool? {
        switch self {
        case .all: return nil
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        }
    }
    func contains(_ source: LogSource) -> Bool {
        guard let tool else { return true }
        return source.tool == tool
    }
}

struct AnalysisPanel: View {
    @ObservedObject var model: AuditorModel
    @State private var category: ContentCategory?
    @State private var scope: AnalysisScope = .all
    @State private var query = ""
    @State private var limit = 30
    @State private var expanded: String?

    private var records: [ContentRecord] {
        (model.analysis?.filtered(today: model.period == .today, now: model.clock) ?? [])
            .filter { scope.contains($0.source) }
    }
    private var prompts: [ContentRecord] { records.filter { $0.kind == .prompt } }
    private var matches: [ContentRecord] {
        prompts.filter { (category == nil || $0.category == category) &&
            (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
    }
    private var tools: [(String, Int)] {
        Dictionary(grouping: records.filter { $0.kind == .tool }, by: \.toolName)
            .map { ($0.key, $0.value.count) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.period == .today ? "今日内容分析" : "历史内容分析").font(.headline)
                Spacer()
                if model.analyzing { ProgressView().controlSize(.small) }
            }
            Text("按用户提示词归类 · 本地关键词规则，可能误分")
                .font(.caption).foregroundStyle(.secondary)
            Picker("应用来源", selection: $scope) {
                ForEach(AnalysisScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            if let analysis = model.analysis {
                HStack {
                    stat("提示词", prompts.count)
                    stat("涉及会话", Set(prompts.map(\.session)).count)
                    stat("AI 回复记录", records.filter { $0.kind == .reply }.count)
                }.padding(12).background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                if analysis.pendingFiles > 0 {
                    Text("正在分批读取 \(analysis.pendingFiles) 个日志，当前分类尚不完整。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if analysis.errors + analysis.skipped > 0 {
                    Text("\(analysis.errors) 处读取失败，\(analysis.skipped) 条无效或过长记录已跳过。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if prompts.isEmpty {
                    Text(model.period == .today ? "今日未发现可识别的用户提示词，可切换历史查看。" : "现存日志中没有可识别的用户提示词。")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    HStack {
                        Text("内容分类").font(.subheadline.weight(.semibold))
                        Spacer()
                        if category != nil { Button("全部分类") { category = nil; resetList() }.font(.caption) }
                    }
                    ForEach(ContentCategory.allCases) { item in
                        let count = prompts.filter { $0.category == item }.count
                        Button { category = category == item ? nil : item; resetList() } label: {
                            VStack(spacing: 5) {
                                HStack {
                                    Label(item.rawValue, systemImage: item.symbol)
                                    Spacer()
                                    Text("\(count) · \(Int(Double(count) / Double(max(1, prompts.count)) * 100))%")
                                        .monospacedDigit()
                                }.font(.caption)
                                GeometryReader { geometry in
                                    Capsule().fill(Color.teal.opacity(0.6))
                                        .frame(width: geometry.size.width * CGFloat(count) / CGFloat(max(1, prompts.count)))
                                }.frame(height: 3).background(Color.primary.opacity(0.04), in: Capsule())
                            }.padding(8).background(category == item ? Color.teal.opacity(0.12) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    Divider()
                    HStack {
                        Text("提示词 · \(matches.count) 条").font(.subheadline.weight(.semibold))
                        Spacer()
                        if let category { Text(category.rawValue).font(.caption).foregroundStyle(.teal) }
                    }
                    TextField("搜索提示词", text: $query).textFieldStyle(.roundedBorder)
                    if matches.isEmpty { Text("没有匹配的提示词").font(.caption).foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(matches.prefix(limit))) { prompt in
                            VStack(alignment: .leading, spacing: 6) {
                                Button { expanded = expanded == prompt.id ? nil : prompt.id } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .top) {
                                            Text(prompt.source.name)
                                            Spacer()
                                            Text(prompt.date.formatted(date: .numeric, time: .shortened))
                                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                                        Text(prompt.text).font(.caption).lineLimit(expanded == prompt.id ? 1 : 3)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        HStack {
                                            Text(prompt.category.rawValue)
                                            Spacer()
                                            Image(systemName: expanded == prompt.id ? "chevron.up" : "chevron.down")
                                        }.font(.system(size: 10)).foregroundStyle(.teal)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if expanded == prompt.id {
                                    Text(prompt.text).font(.caption).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if prompt.text.count >= 12_000 {
                                        Text("仅显示前 12,000 字符").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    if matches.count > limit { Button("再显示 30 条") { limit += 30 }.font(.caption) }
                }
                if !tools.isEmpty {
                    Divider()
                    Text("工具活动 · 当前期间与来源").font(.subheadline.weight(.semibold))
                    ForEach(Array(tools.prefix(8)), id: \.0) { name, count in
                        HStack { Text(name).lineLimit(1).help(name); Spacer(); Text(count.formatted()).monospacedDigit() }.font(.caption)
                    }
                    Text("Claude 明确标记的工具错误：\(records.filter { $0.kind == .toolError }.count)；Codex 工具错误暂不统计。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("更新于 \(analysis.checkedAt.formatted(date: .omitted, time: .standard))。历史含今日，仅覆盖仍保留在本机的日志。分类占比按提示词条数计算，不代表 token 占比。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.demo ? "演示模式不读取真实对话；正常启动后可使用内容分析。" : (model.paused ? "采集已暂停；恢复采集后读取内容。" : "首次分析正在读取本地日志…"))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical)
            }
            Text("提示词仅在内存中分析与展示，不另存、不上传。已过滤已知系统上下文与工具结果；未识别的注入内容仍可能混入。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: model.period) { _ in resetList() }
        .onChange(of: scope) { _ in resetList() }
        .onChange(of: query) { _ in resetList() }
    }
    private func resetList() { limit = 30; expanded = nil }
    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

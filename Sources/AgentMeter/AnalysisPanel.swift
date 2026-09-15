import SwiftUI
import AuditorCore

/// Analysis is filtered by tool, not by individual entrypoint: the per-entrypoint
/// split matters for token accounting, not for what was being asked about.
/// Modelled as three explicit cases rather than an optional so that the
/// segmented picker has an unambiguous tag for "all".
enum AnalysisScope: String, CaseIterable, Identifiable {
    case all, claudeCode, codex
    var id: String { rawValue }
    func name(_ copy: Copy) -> String {
        switch self {
        case .all: return copy.allSources
        case .claudeCode: return LogTool.claudeCode.name
        case .codex: return LogTool.codex.name
        }
    }
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
    private var copy: Copy { model.copy }

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
                Text(copy.analysisTitle(model.period)).font(.headline)
                Spacer()
                if model.analyzing { ProgressView().controlSize(.small) }
            }
            Text(copy.analysisCaption)
                .font(.caption).foregroundStyle(.secondary)
            Picker(copy.sourceApp, selection: $scope) {
                ForEach(AnalysisScope.allCases) { scope in
                    Text(scope.name(copy)).tag(scope)
                }
            }
            if let analysis = model.analysis {
                HStack {
                    stat(copy.prompts, prompts.count)
                    stat(copy.sessions, Set(prompts.map(\.session)).count)
                    stat(copy.replies, records.filter { $0.kind == .reply }.count)
                }.padding(12).background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                if analysis.pendingFiles > 0 {
                    Text(copy.stillReading(analysis.pendingFiles))
                        .font(.caption).foregroundStyle(.orange)
                }
                if analysis.errors + analysis.skipped > 0 {
                    Text(copy.analysisSkipped(errors: analysis.errors, skipped: analysis.skipped))
                        .font(.caption).foregroundStyle(.orange)
                }
                if prompts.isEmpty {
                    Text(copy.noPrompts(model.period))
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    HStack {
                        Text(copy.categories).font(.subheadline.weight(.semibold))
                        Spacer()
                        if category != nil { Button(copy.allCategories) { category = nil; resetList() }.font(.caption) }
                    }
                    ForEach(ContentCategory.allCases) { item in
                        let count = prompts.filter { $0.category == item }.count
                        Button { category = category == item ? nil : item; resetList() } label: {
                            VStack(spacing: 5) {
                                HStack {
                                    Label(item.name(model.language), systemImage: item.symbol)
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
                        Text(copy.promptCount(matches.count)).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let category { Text(category.name(model.language)).font(.caption).foregroundStyle(.teal) }
                    }
                    TextField(copy.searchPrompts, text: $query).textFieldStyle(.roundedBorder)
                    if matches.isEmpty { Text(copy.noMatches).font(.caption).foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(matches.prefix(limit))) { prompt in
                            VStack(alignment: .leading, spacing: 6) {
                                Button { expanded = expanded == prompt.id ? nil : prompt.id } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .top) {
                                            Text(prompt.source.name(model.language))
                                            Spacer()
                                            Text(prompt.date.formatted(date: .numeric, time: .shortened))
                                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                                        Text(prompt.text).font(.caption).lineLimit(expanded == prompt.id ? 1 : 3)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        HStack {
                                            Text(prompt.category.name(model.language))
                                            Spacer()
                                            Image(systemName: expanded == prompt.id ? "chevron.up" : "chevron.down")
                                        }.font(.system(size: 10)).foregroundStyle(.teal)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if expanded == prompt.id {
                                    Text(prompt.text).font(.caption).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if prompt.text.count >= 12_000 {
                                        Text(copy.truncated).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    if matches.count > limit { Button(copy.showMore) { limit += 30 }.font(.caption) }
                }
                if !tools.isEmpty {
                    Divider()
                    Text(copy.toolActivity).font(.subheadline.weight(.semibold))
                    ForEach(Array(tools.prefix(8)), id: \.0) { name, count in
                        HStack { Text(name).lineLimit(1).help(name); Spacer(); Text(count.formatted()).monospacedDigit() }.font(.caption)
                    }
                    Text(copy.toolErrors(records.filter { $0.kind == .toolError }.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(copy.analysisFooter(analysis.checkedAt.formatted(date: .omitted, time: .standard)))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.demo ? copy.analysisDemo : (model.paused ? copy.analysisPaused : copy.analysisFirstRun))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical)
            }
            Text(copy.analysisPrivacy)
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

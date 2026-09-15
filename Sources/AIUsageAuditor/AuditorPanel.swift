import SwiftUI
import AppKit
import AuditorCore

struct AuditorPanel: View {
    @ObservedObject var model: AuditorModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.teal)
                        .padding(10).background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Usage Auditor").font(.headline)
                        Text("LOG USAGE  ·  日志上报用量").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(model.error != nil ? .red : (model.paused ? .orange : .teal)).frame(width: 8, height: 8)
                }
                Picker("统计期间", selection: $model.period) {
                    ForEach(LogPeriod.allCases, id: \.self) { period in Text(period.rawValue).tag(period) }
                }.pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(model.period == .today ? "今日 · 全部日志来源" : "已导入历史 · 全部来源").font(.subheadline.weight(.semibold))
                        Spacer()
                        if model.scanning { ProgressView().controlSize(.small) }
                    }
                    HStack(spacing: 18) {
                        metric("↑ INPUT", value: model.totals.input, color: .teal)
                        Divider().frame(height: 40)
                        metric("↓ OUTPUT", value: model.totals.output, color: .indigo)
                    }
                    Text("\(model.totals.records.formatted()) 条去重用量记录 · 总计 \(model.totals.total.formatted()) tokens")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    Text("按日志入口分类").font(.subheadline.weight(.semibold))
                    ForEach(model.sources) { source in
                        let totals = model.totals(for: source)
                        Button { model.selectedSource = source } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(source.name).fontWeight(.semibold)
                                    Spacer()
                                    if model.selectedSource == source { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal) }
                                }
                                if source == .claudeDesktop {
                                    Text("不包含普通 Chat 聊天").foregroundStyle(.secondary)
                                }
                                if model.events.contains(where: { $0.source == source }) {
                                    if totals.records == 0 {
                                        Text("当前期间暂无可计入的日志用量").foregroundStyle(.secondary)
                                    } else {
                                        Text("↑ \(totals.input.formatted())   ↓ \(totals.output.formatted())   · \(totals.records) 条")
                                            .monospacedDigit().foregroundStyle(.secondary)
                                    }
                                } else { Text("未发现用量记录").foregroundStyle(.secondary) }
                            }.font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedSource == source ? .teal.opacity(0.10) : Color.primary.opacity(0.03),
                                            in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text(model.selectedSource.name).font(.subheadline.weight(.semibold))
                    Text(model.provenance).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    detail("缓存读取 · 输入的一部分", value: model.selectedTotals.cacheRead,
                           unknown: model.selectedTotals.missingCache)
                    detail("缓存写入 · 输入的一部分", value: model.selectedTotals.cacheWrite,
                           unknown: model.selectedTotals.missingCache)
                    if model.selectedSource.tool == .codex {
                        detail("推理 · 输出的一部分", value: model.selectedTotals.reasoning,
                               unknown: model.selectedTotals.missingReasoning)
                    }
                    if let date = model.lastUsage {
                        Text("最近用量记录：\(date.formatted(date: .numeric, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.selectedTotals.records == 0 {
                            Text("当前统计期间没有可计入记录；不代表账号实际消耗为零。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.status, systemImage: model.paused ? "pause.circle" : "doc.text.magnifyingglass")
                        .font(.caption)
                    if let date = model.result?.checkedAt {
                        Text("最近检查 \(date.formatted(date: .omitted, time: .standard)) · Claude Code \(model.result?.filesByTool[.claudeCode] ?? 0) 个文件 · Codex \(model.result?.filesByTool[.codex] ?? 0) 个文件")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                    ForEach(model.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }.fixedSize(horizontal: false, vertical: true)
                Text("仅统计本机 Claude 编程代理与 Codex 日志，不覆盖普通 Claude / ChatGPT 聊天。输入已含缓存，输出可能含推理，不重复相加；用量不等于订阅额度或账单。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.paused ? "恢复采集" : "暂停采集") { model.togglePaused() }.disabled(model.demo)
                    Button("刷新") { model.refreshNow() }.disabled(model.demo || model.scanning || model.paused)
                    Menu {
                        Button("打开来源日志目录") { model.openLogFolder() }
                        Button("打开本地账本目录") { model.openDataFolder() }
                        Button("在独立窗口查看") { openWindow(id: "preview"); NSApp.activate(ignoringOtherApps: true) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
                    Spacer()
                    Button("退出") { NSApp.terminate(nil) }.foregroundStyle(.secondary)
                }.controlSize(.small)
            }.padding(22)
        }.frame(width: 460, height: panelHeight)
    }
    private var panelHeight: CGFloat {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return min(780, max(320, (screen?.visibleFrame.height ?? 840) - 40))
    }
    private func metric(_ title: String, value: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(color)
            Text(model.result == nil ? "—" : value.formatted())
                .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.5).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func detail(_ title: String, value: Int64, unknown: Bool) -> some View {
        HStack {
            Text(title); Spacer()
            Text(model.selectedTotals.records == 0 ? "—" : (unknown ? "已知 \(value.formatted()) · 部分未上报" : value.formatted()))
                .monospacedDigit()
        }.font(.caption).foregroundStyle(.secondary)
    }
}

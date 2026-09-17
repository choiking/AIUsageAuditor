import SwiftUI
import AppKit
import AuditorCore

struct AuditorPanel: View {
    @ObservedObject var model: AuditorModel
    @Environment(\.openWindow) private var openWindow
    private var copy: Copy { model.copy }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.teal)
                        .padding(10).background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy.appName).font(.headline)
                        Text(copy.subtitle).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(model.error != nil ? .red : (model.paused ? .orange : .teal)).frame(width: 8, height: 8)
                }
                tabBar
                Picker("", selection: $model.period) {
                    ForEach(LogPeriod.allCases, id: \.self) { period in
                        Text(copy.periodName(period)).tag(period)
                    }
                }.pickerStyle(.segmented).labelsHidden()

                if model.tab == .analysis {
                    AnalysisPanel(model: model)
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(copy.totalsHeading(model.period)).font(.subheadline.weight(.semibold))
                        Spacer()
                        if model.scanning { ProgressView().controlSize(.small) }
                    }
                    HStack(spacing: 18) {
                        metric("↑ INPUT", value: model.totals.input, color: .teal)
                        Divider().frame(height: 40)
                        metric("↓ OUTPUT", value: model.totals.output, color: .indigo)
                    }
                    Text(copy.recordSummary(records: model.totals.records, total: model.totals.total))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 12) {
                    Text(copy.byToolHeading).font(.subheadline.weight(.semibold))
                    ForEach(model.tools) { tool in
                        VStack(alignment: .leading, spacing: 6) {
                            row(for: .tool(tool), emphasised: true)
                            if model.isExpanded(tool) {
                                ForEach(model.sources(in: tool)) { source in
                                    row(for: .source(source), emphasised: false)
                                        .padding(.leading, 14)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text(model.selection.name(model.language)).font(.subheadline.weight(.semibold))
                    Text(model.provenance).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    breakdown
                    costRow

                    if let date = model.lastUsage {
                        Text(copy.lastUsage(date.formatted(date: .numeric, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                        if model.selectedTotals.records == 0 {
                            Text(copy.emptyPeriodNote)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.status, systemImage: model.paused ? "pause.circle" : "doc.text.magnifyingglass")
                        .font(.caption)
                    if let date = model.result?.checkedAt {
                        Text(copy.lastChecked(date.formatted(date: .omitted, time: .standard),
                                             claude: model.result?.filesByTool[.claudeCode] ?? 0,
                                             codex: model.result?.filesByTool[.codex] ?? 0))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                    ForEach(model.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }.fixedSize(horizontal: false, vertical: true)
                Text(copy.footerNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.paused ? copy.resume : copy.pause) { model.togglePaused() }.disabled(model.demo)
                    Button(copy.refresh) { model.refreshNow() }.disabled(model.demo || model.scanning || model.analyzing || model.paused)
                    OverflowMenu(copy: copy, language: $model.language,
                                 showLogFolder: model.openLogFolder,
                                 showDataFolder: model.openDataFolder,
                                 showWindow: { openWindow(id: "preview"); NSApp.activate(ignoringOtherApps: true) })
                        .equatable()
                    Spacer()
                    Button(copy.quit) { NSApp.terminate(nil) }.foregroundStyle(.secondary)
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
    /// Pulled out of the panel body and made equatable so that a finished scan
    /// cannot rebuild this menu while it is open underneath the pointer. Only a
    /// language change alters anything inside it.
    private struct OverflowMenu: View, Equatable {
        let copy: Copy
        @Binding var language: AppLanguage
        let showLogFolder: () -> Void
        let showDataFolder: () -> Void
        let showWindow: () -> Void
        static func == (a: OverflowMenu, b: OverflowMenu) -> Bool { a.copy.language == b.copy.language }
        var body: some View {
            Menu {
                Button(copy.openLogFolder) { showLogFolder() }
                Button(copy.openDataFolder) { showDataFolder() }
                Button(copy.openWindow) { showWindow() }
                Divider()
                // A submenu rather than a preferences window: the panel has no
                // other settings to keep it company.
                Picker(copy.languageMenu, selection: $language) {
                    ForEach(AppLanguage.allCases) { language in Text(language.menuLabel).tag(language) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 24)
        }
    }

    /// Page navigation, styled as an underlined tab bar rather than a second
    /// segmented picker. The period control below it is a filter, not
    /// navigation, and the two were previously indistinguishable.
    @ViewBuilder private var tabBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                ForEach(AuditorTab.allCases) { tab in
                    let active = model.tab == tab
                    Button {
                        model.tab = tab
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                                Text(copy.tabName(tab)).font(.callout.weight(active ? .semibold : .regular))
                            }
                            .foregroundStyle(active ? Color.teal : Color.secondary)
                            .frame(maxWidth: .infinity)
                            // A continuous hairline with a thicker accent under the
                            // active tab; equal heights keep the rule aligned.
                            Capsule().fill(active ? Color.teal : Color.primary.opacity(0.10))
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                }
            }
            Text(copy.tabCaption(model.tab)).font(.caption2).foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.15), value: model.tab)
    }

    /// Full token breakdown for the selected scope, mirroring the fields the
    /// log actually reports. Each row names its source field so the number can
    /// be traced back to the JSONL rather than taken on trust.
    @ViewBuilder private var breakdown: some View {
        let totals = model.selectedTotals
        if model.selection.tool == .claudeCode {
            detail(copy.uncachedInput, field: "input_tokens", value: totals.uncachedInput, unknown: totals.missingCache)
            detail(copy.cacheRead, field: "cache_read_input_tokens", value: totals.cacheRead, unknown: totals.missingCache)
            detail(copy.cacheWrite, field: "cache_creation_input_tokens", value: totals.cacheWrite, unknown: totals.missingCache)
            detail(copy.ttl1h, field: "ephemeral_1h_input_tokens", value: totals.cacheWrite1h,
                   unknown: totals.missingWriteTTL, nested: true)
            detail(copy.ttl5m, field: "ephemeral_5m_input_tokens", value: totals.cacheWrite5m,
                   unknown: totals.missingWriteTTL, nested: true)
            detail(copy.output, field: "output_tokens", value: totals.output, unknown: false)
            Text(copy.claudeBreakdownNote)
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            detail(copy.input, field: "input_tokens", value: totals.input, unknown: false)
            detail(copy.ofWhichCacheRead, field: "cached_input_tokens", value: totals.cacheRead,
                   unknown: totals.missingCache, nested: true)
            detail(copy.ofWhichCacheWrite, field: "cache_write_input_tokens", value: totals.cacheWrite,
                   unknown: totals.missingCache, nested: true)
            detail(copy.output, field: "output_tokens", value: totals.output, unknown: false)
            detail(copy.ofWhichReasoning, field: "reasoning_output_tokens", value: totals.reasoning,
                   unknown: totals.missingReasoning, nested: true)
            detail(copy.total, field: "total_tokens", value: totals.total, unknown: false)
            Text(copy.codexBreakdownNote)
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One selectable row. `emphasised` marks the top-level tool category,
    /// whose totals are the sum of the entrypoint rows nested under it.
    @ViewBuilder private func row(for selection: MeterSelection, emphasised: Bool) -> some View {
        let totals = model.totals(for: selection)
        let selected = model.selection == selection
        let present = model.events.contains { selection.contains($0.source) }
        Button {
            model.selection = selection
            if case .tool(let tool) = selection { model.toggleExpansion(tool) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if case .tool(let tool) = selection {
                        Image(systemName: model.isExpanded(tool) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 10)
                    }
                    Text(selection.name(model.language))
                        .font(emphasised ? .callout.weight(.semibold) : .caption.weight(.semibold))
                    if case .tool(let tool) = selection, !model.isExpanded(tool) {
                        Text(copy.entryCount(model.sources(in: tool).count)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal) }
                }
                if present {
                    if totals.records == 0 {
                        Text(copy.noCountableUsage).foregroundStyle(.secondary)
                    } else {
                        Text(copy.rowTotals(totals)).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else { Text(copy.noRecordsFound).foregroundStyle(.secondary) }
            }.font(.caption).padding(emphasised ? 12 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? .teal.opacity(0.10)
                                     : Color.primary.opacity(emphasised ? 0.06 : 0.03),
                            in: RoundedRectangle(cornerRadius: emphasised ? 11 : 9))
        }.buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: model.expandedTools)
    }

    /// List-price estimate. Deliberately never called spend: the logs record no
    /// billing mode, so a subscription user pays a flat fee regardless of this.
    @ViewBuilder private var costRow: some View {
        let cost = model.selectedCost
        Divider().padding(.vertical, 1)
        if cost.hasAnything {
            HStack(alignment: .firstTextBaseline) {
                Text(copy.costTitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(cost.amount, format: .currency(code: "USD"))
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            Text(copy.costNote)
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !cost.isComplete {
                Text(copy.unpricedNote(cost)).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(copy.noPriceableRecords).font(.caption).foregroundStyle(.secondary)
            if !cost.unpricedModels.isEmpty {
                Text(copy.unpricedNote(cost)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `field` is the JSONL key this number is summed from; showing it keeps the
    /// panel honest about which reported value each row represents.
    private func detail(_ title: String, field: String, value: Int64,
                        unknown: Bool, nested: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Text(field)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 6)
            Text(model.selectedTotals.records == 0 ? "—"
                 : (unknown ? copy.partiallyKnown(value) : value.formatted()))
                .monospacedDigit()
        }
        .font(.caption).foregroundStyle(nested ? .tertiary : .secondary)
        .padding(.leading, nested ? 12 : 0)
    }
}

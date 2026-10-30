import MelonCore
import SwiftUI

extension SecurityReport.Kind {
    var title: String {
        switch self {
        case .weak: "弱密码"
        case .reused: "重复使用"
        case .no2fa: "未开启两步验证"
        case .old: "长期未更新"
        }
    }

    var symbol: String {
        switch self {
        case .weak: "lock.open"
        case .reused: "doc.on.doc"
        case .no2fa: "iphone"
        case .old: "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .weak: Theme.danger
        case .reused, .no2fa: Theme.warn
        case .old: Theme.text2
        }
    }

    var severity: String {
        switch self {
        case .weak: "高"
        case .reused, .no2fa: "中"
        case .old: "低"
        }
    }

    /// 条目顶部提示里的按钮文字
    var fixLabel: String {
        switch self {
        case .weak, .reused: "修改密码"
        case .no2fa: "添加验证码"
        case .old: "更新"
        }
    }
}

extension SecurityReport.Issue {
    func message(titles: [String: String]) -> String {
        switch kind {
        case .weak: return "密码强度弱，容易被猜到"
        case .reused:
            let names = sharedWith.compactMap { titles[$0] }.prefix(3).map { "「\($0)」" }.joined(separator: "、")
            return sharedWith.count == 1 ? "和\(names)用的是同一个密码" : "和\(names)等 \(sharedWith.count) 个条目用的是同一个密码"
        case .no2fa: return "这个网站支持两步验证，但还没有添加一次性验证码"
        case .old: return "已经超过一年没有更新"
        }
    }
}

/// 安全报告：放在中间一栏。上面是健康分和四类问题的数量（点了按类型筛选），
/// 下面是问题列表；点一个问题，右边显示对应条目。
struct SecurityReportColumn: View {
    let report: SecurityReport
    let index: ItemIndex
    @Binding var filter: SecurityReport.Kind?
    @Binding var selectedID: String?
    /// 恢复一个忽略了的问题
    var onRestore: (SecurityReport.Issue) -> Void = { _ in }

    /// 看的是忽略了的问题（点「已忽略」切换）
    @State private var showIgnored = false

    private var titles: [String: String] { index.titles }
    private var shown: [SecurityReport.Issue] {
        (showIgnored ? report.ignored : report.issues).filter { filter == nil || $0.kind == filter }
            .sorted { ($0.kind, $0.itemId) < ($1.kind, $1.itemId) }
    }

    private var scoreColor: Color { report.score >= 80 ? Theme.ok : report.score >= 60 ? Theme.warn : Theme.danger }
    private var scoreLabel: String { report.score >= 80 ? "良好" : report.score >= 60 ? "一般" : "较差" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().stroke(Theme.line2, lineWidth: 5)
                            Circle().trim(from: 0, to: CGFloat(report.score) / 100)
                                .stroke(scoreColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(report.score)").font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                        }
                        .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("保险库健康度：\(scoreLabel)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(report.issues.isEmpty ? "所有条目都很安全。只在本机计算，不联网。"
                                 : "\(report.itemsWithIssues.count) 个条目有 \(report.issues.count) 个问题，优先处理弱密码和重复使用的密码。")
                                .font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(SecurityReport.Kind.allCases, id: \.self) { kind in tile(kind) }
                    }
                }
                .padding(.horizontal, 18).padding(.top, 46).padding(.bottom, 14)

                RowDivider()

                HStack {
                    Text((showIgnored ? "已忽略 · " : "") + (filter?.title ?? "全部问题"))
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text3)
                    Spacer()
                    if filter != nil {
                        Button("显示全部") { filter = nil }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(Theme.accentText)
                    }
                    if showIgnored || !report.ignored.isEmpty {
                        Button(showIgnored ? "返回" : "已忽略（\(report.ignored.count)）") { showIgnored.toggle() }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(Theme.accentText)
                            .help(showIgnored ? "回到需要处理的问题" : "看看忽略了哪些问题，可以恢复")
                    }
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)

                if shown.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(Theme.accent)
                        Text(showIgnored ? "没有忽略的问题" : "没有需要处理的问题").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }

                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { issue in
                        if let e = index.entry(issue.itemId) {
                            HStack(spacing: 12) {
                                ItemIcon(type: e.item.type, size: 36, iconData: e.item.iconData, title: e.item.title)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(issue.message(titles: titles)).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                if showIgnored {
                                    Button("恢复") { onRestore(issue) }.buttonStyle(.borderless)
                                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accentText)
                                        .help("重新提示这个问题")
                                } else {
                                    Text(issue.kind.severity).font(.system(size: 11, weight: .medium)).foregroundStyle(issue.kind.tint)
                                        .padding(.horizontal, 7).padding(.vertical, 1)
                                        .background(Capsule().fill(Theme.hover))
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 12).fill(selectedID == issue.itemId ? Theme.accentSoft : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = issue.itemId }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(Theme.list)
    }

    private func tile(_ kind: SecurityReport.Kind) -> some View {
        let active = filter == kind
        return Button { filter = active ? nil : kind } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(kind.title, systemImage: kind.symbol).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                    .lineLimit(1)
                Text("\(report.count(kind))").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(report.count(kind) > 0 ? kind.tint : Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11).fill(active ? Theme.accentSoft : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(active ? Theme.accent : Theme.line2, lineWidth: active ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 条目详情顶部：这个条目有哪些安全问题，每条带一个「去修改」的按钮和一个「忽略」的 ×
struct IssueBanners: View {
    let issues: [SecurityReport.Issue]
    let titles: [String: String]
    let onFix: () -> Void
    var onIgnore: (SecurityReport.Kind) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(issues) { issue in
                HStack(spacing: 8) {
                    Image(systemName: issue.kind.symbol).font(.system(size: 13)).foregroundStyle(issue.kind.tint)
                    Text(issue.message(titles: titles)).font(.system(size: 12.5))
                    Spacer(minLength: 0)
                    Button(issue.kind.fixLabel, action: onFix)
                        .buttonStyle(.borderless)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                    Button { onIgnore(issue.kind) } label: {
                        Image(systemName: "xmark").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("忽略这个提示：不再提醒、不扣健康分。可以在安全报告的「已忽略」里恢复")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentSoft))
            }
        }
    }
}

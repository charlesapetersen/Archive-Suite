import SwiftUI

/// The settings sheet's range tab (W46.settings-range-view; `12-settings-design.md` §3.4): one chart per stage from
/// `SettingsRangeChart`, the full table beneath it, and the after-training points the fine-tuning answer allows. Drawn
/// in plain SwiftUI shapes so the self-test's offscreen render sees every mark. A click chooses as the card's override
/// does; clicking the app's own pick is the way back.
struct SettingsRangeTab: View {
    let model: SettingsSheetModel
    var choose: (String, String?) -> Void = { _, _ in }

    var body: some View {
        Text("Every measured choice for each step, set out by price and figure, so you can see the whole range and pick "
             + "another. The figures are the same ones the cards use.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        RangeLegend(kit: model.ranges.contains { $0.kit.contains { $0.y != nil } })
        ForEach(model.ranges) { chart in
            SheetBox {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chart.title).font(.headline)
                    Text("Now: \(chart.pickName)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } content: {
                RangeChartBlock(chart: chart, choose: { id in
                    choose(chart.id, id == chart.appPickID ? nil : id)
                })
            }
            .accessibilityIdentifier("ap.sheet.range.\(chart.id)")
        }
    }
}

/// The key to the marks, once above the charts.
private struct RangeLegend: View {
    /// An after-training star is drawn on some chart.
    let kit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .center, spacing: 14) {
            ForEach([SettingsRouteTable.Family.mac, .cloud, .plan, .cluster], id: \.self) { f in
                HStack(spacing: 4) {
                    RangeMark(family: f, state: .usable, picked: false, kit: false).frame(width: 12, height: 12)
                    Text(Self.word(f)).font(.caption2)
                }
            }
            HStack(spacing: 4) {
                RangeMark(family: .mac, state: .unusable, picked: false, kit: false).frame(width: 12, height: 12)
                Text("cannot be used here").font(.caption2)
            }
            HStack(spacing: 4) {
                RangeMark(family: .mac, state: .outsideLimits, picked: false, kit: false).frame(width: 12, height: 12)
                Text("breaks your limits").font(.caption2)
            }
        }
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 4) {
                RangeMark(family: .mac, state: .usable, picked: true, kit: false).frame(width: 12, height: 12)
                Text("chosen now").font(.caption2)
            }
            HStack(spacing: 4) {
                Circle().stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [3, 2])).frame(width: 12, height: 12)
                Text("your choices together").font(.caption2)
            }
            HStack(spacing: 4) {
                Circle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])).frame(width: 12, height: 12)
                Text("nothing beats it").font(.caption2)
            }
            if kit {
                HStack(spacing: 4) {
                    RangeMark(family: .kit, state: .usable, picked: false, kit: true).frame(width: 12, height: 12)
                    Text("after training").font(.caption2)
                }
            }
        }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ap.sheet.range.legend")
    }

    static func word(_ f: SettingsRouteTable.Family) -> String {
        switch f {
        case .mac: return "this Mac"
        case .cloud: return "a paid service"
        case .plan: return "a subscription plan"
        case .cluster: return "a computing cluster"
        case .manual: return "by hand"
        case .kit: return "after training"
        }
    }
}

/// One mark: the shape says the family, fill and opacity the state, a ring the pick.
struct RangeMark: View {
    let family: SettingsRouteTable.Family
    let state: SettingsRangeChart.State
    let picked: Bool
    let kit: Bool

    var body: some View {
        let color: Color = kit ? .purple : state == .unusable ? .secondary : .accentColor
        ZStack {
            if state == .unusable || kit {
                RangeShape(family: kit ? .kit : family).stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: kit ? [2, 2] : []))
            } else {
                RangeShape(family: family).fill(color)
            }
            if picked {
                Circle().stroke(Color.orange, lineWidth: 2).scaleEffect(1.7)
            }
        }
        .opacity(state == .outsideLimits && !picked ? 0.35 : 1)
    }
}

struct RangeShape: Shape {
    let family: SettingsRouteTable.Family

    func path(in r: CGRect) -> Path {
        var p = Path()
        switch family {
        case .mac, .manual:
            p.addEllipse(in: r)
        case .cloud:
            p.addRect(r.insetBy(dx: r.width * 0.08, dy: r.height * 0.08))
        case .plan:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        case .cluster:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .kit:
            let c = CGPoint(x: r.midX, y: r.midY), outer = r.width / 2, inner = r.width / 4.5
            for i in 0..<10 {
                let a = Double(i) * .pi / 5 - .pi / 2
                let rad = i.isMultiple(of: 2) ? outer : inner
                let pt = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
        return p
    }
}

/// One stage: its chart, the red line's words, the after-training points, and the full table.
private struct RangeChartBlock: View {
    let chart: SettingsRangeChart
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chart.caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RangePlot(chart: chart, choose: choose)
                .frame(height: 280)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ap.sheet.range.\(chart.id).chart")
            if let t = chart.together {
                Text("Orange dashed ring: \(t.text)").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let c = chart.ceilingText {
                Text(c).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !chart.offChart.isEmpty {
                Text("In the table but not on the chart (they find nothing by themselves, or were measured another way): "
                     + chart.offChart.joined(separator: "; ") + ".")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !chart.kit.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("After training on your own material").font(.caption.weight(.semibold))
                    ForEach(chart.kit) { k in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(k.name).font(.caption).bold().fixedSize(horizontal: false, vertical: true)
                            if let m = k.measured {
                                Text("Measured: \(m)." + (k.y != nil ? " Drawn as a star on the chart." : ""))
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                            Text(k.condition).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("ap.sheet.range.\(chart.id).kit.\(k.id)")
                    }
                    if chart.kit.contains(where: { !$0.caveats.isEmpty }) {
                        DisclosureGroup("Notes from the measurements") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(SettingsSheetWords.uniqueStrings(chart.kit.flatMap(\.caveats)), id: \.self) {
                                    Text("• \($0)").font(.caption2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.07)))
            }
            Text("Every choice").font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(chart.rows) { row in
                    RangeRow(row: row, stage: chart.id, choose: choose)
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RangeRow: View {
    let row: SettingsRangeChart.Row
    let stage: String
    let choose: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.name).font(.caption.weight(row.picked ? .bold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    if !row.familyWord.isEmpty {
                        Text("(\(row.familyWord))").font(.caption2).foregroundStyle(.secondary)
                    }
                    if row.appPick { Text("the app's own pick").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                    if row.picked {
                        Text(row.pickedPart ? "now chosen for part of this step" : "now chosen")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                Text(row.figures).font(.caption2).fixedSize(horizontal: false, vertical: true)
                if let p = row.publicFigure { Text(p).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("\(row.listPrice); \(row.batchCost); \(row.time); \(row.canUse).")
                    .font(.caption2)
                    .foregroundStyle(row.state == .usable ? Color.secondary : row.state == .outsideLimits ? Color.orange : Color.red.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if row.choosable {
                Button(row.pickedPart ? "Use for all of this step" : row.appPick ? "Go back to it" : "Choose") { choose(row.id) }
                    .controlSize(.small)
                    .accessibilityIdentifier("ap.sheet.range.\(stage).choose.\(row.id)")
            }
        }
        .padding(.vertical, 3)
        .opacity(row.state == .unusable ? 0.75 : 1)
    }
}

/// The chart itself: axes, the free band, the undominated line, the red line, the marks.
private struct RangePlot: View {
    let chart: SettingsRangeChart
    let choose: (String) -> Void

    private let insets = EdgeInsets(top: 10, leading: 40, bottom: 30, trailing: 12)
    private let band: CGFloat = 100

    var body: some View {
        GeometryReader { geo in
            let g = Geometry(chart: chart, size: geo.size, insets: insets, band: band)
            ZStack(alignment: .topLeading) {
                // The free band.
                Rectangle().fill(Color.green.opacity(0.10))
                    .frame(width: band, height: g.plot.height)
                    .position(x: g.plot.minX + band / 2, y: g.plot.midY)
                Text("free").font(.caption2).foregroundStyle(.secondary)
                    .position(x: g.plot.minX + band / 2, y: g.plot.maxY + 10)
                // Axes and grid.
                Path { p in
                    p.move(to: CGPoint(x: g.plot.minX, y: g.plot.minY))
                    p.addLine(to: CGPoint(x: g.plot.minX, y: g.plot.maxY))
                    p.addLine(to: CGPoint(x: g.plot.maxX, y: g.plot.maxY))
                }
                .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                ForEach(g.yTicks, id: \.self) { t in
                    Path { p in
                        p.move(to: CGPoint(x: g.plot.minX, y: g.y(t)))
                        p.addLine(to: CGPoint(x: g.plot.maxX, y: g.y(t)))
                    }
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    Text(SettingsSolver.num(t)).font(.caption2).foregroundStyle(.secondary)
                        .position(x: g.plot.minX - 16, y: g.y(t))
                }
                ForEach(g.xTicks, id: \.self) { t in
                    Path { p in
                        p.move(to: CGPoint(x: g.x(t), y: g.plot.minY))
                        p.addLine(to: CGPoint(x: g.x(t), y: g.plot.maxY))
                    }
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    Text(Self.money(t)).font(.caption2).foregroundStyle(.secondary)
                        .position(x: g.x(t), y: g.plot.maxY + 10)
                }
                Text(chart.xLabel).font(.caption2).foregroundStyle(.secondary)
                    .position(x: (g.plot.minX + band + g.plot.maxX) / 2, y: g.plot.maxY + 23)
                if g.pinned {
                    Text("marks on the bottom edge score lower than \(SettingsSolver.num(g.yLo))")
                        .font(.caption2).italic().foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: g.plot.maxX - 110, y: g.plot.maxY - 8)
                }
                // The undominated line.
                Path { p in
                    for (i, pt) in chart.frontier.enumerated() {
                        let c = g.center(pt)
                        if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
                    }
                }
                .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                if chart.frontier.count == 1, let only = chart.frontier.first {
                    // One choice beats the rest: a dashed ring instead of a line.
                    Circle().stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                        .frame(width: 22, height: 22)
                        .position(g.center(only))
                }
                // What is left of the ceiling.
                if let c = chart.ceilingPer1000 {
                    // Far beyond every price, the line sits at the right edge and says so.
                    let beyond = c > g.hi
                    let x = c <= 0 ? g.plot.minX + band : beyond ? g.plot.maxX : g.x(c)
                    Path { p in
                        p.move(to: CGPoint(x: x, y: g.plot.minY))
                        p.addLine(to: CGPoint(x: x, y: g.plot.maxY))
                    }
                    .stroke(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    Text(beyond ? "your limit: \(Self.money(c)), off the chart →" : "your limit")
                        .font(.caption2).foregroundStyle(.red)
                        .fixedSize()
                        .position(x: beyond ? x - 70 : min(x + 30, g.plot.maxX - 30), y: g.plot.minY + 6)
                }
                // The marks: unusable first, so the usable ones sit on top.
                ForEach(chart.points.sorted { ($0.state == .unusable ? 0 : 1, $0.picked ? 1 : 0) < ($1.state == .unusable ? 0 : 1, $1.picked ? 1 : 0) }) { pt in
                    // Not disabled, so the tooltip still shows why a hollow mark cannot be chosen.
                    Button { if pt.choosable { choose(pt.id) } } label: {
                        RangeMark(family: pt.family, state: pt.state, picked: pt.picked, kit: false)
                            .frame(width: pt.picked ? 12 : 10, height: pt.picked ? 12 : 10)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(pt.tooltip)
                    .accessibilityLabel(pt.tooltip)
                    .accessibilityIdentifier("ap.sheet.range.\(chart.id).mark.\(pt.id)")
                    .position(g.center(pt))
                }
                ForEach(chart.kit.filter { $0.y != nil }) { k in
                    RangeMark(family: .kit, state: .usable, picked: false, kit: true)
                        .frame(width: 13, height: 13)
                        .help("\(k.name): after training. \(k.measured ?? "") \(k.condition)")
                        .position(x: g.plot.minX + band * 0.85, y: g.y(k.y!))
                }
                if let t = chart.together {
                    let c = CGPoint(x: t.x == 0 ? g.plot.minX + band * 0.5 : g.x(t.x), y: g.y(t.y))
                    Circle().stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                        .frame(width: 16, height: 16)
                        .help(t.text)
                        .accessibilityLabel(t.text)
                        .accessibilityIdentifier("ap.sheet.range.\(chart.id).together")
                        .position(c)
                    Text("together").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        .fixedSize()
                        .position(x: c.x, y: c.y + 14)
                }
                // The pick's name beside its mark.
                ForEach(chart.points.filter(\.lead)) { pt in
                    let c = g.center(pt)
                    Text(pt.name.components(separatedBy: ",")[0].components(separatedBy: " (")[0]).font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .position(x: min(c.x + 60, g.plot.maxX - 40), y: max(c.y - 13, g.plot.minY + 6))
                }
            }
        }
    }

    static func money(_ x: Double) -> String {
        x >= 1 ? String(format: "$%.0f", x) : String(format: "$%.2g", x)
    }

    /// Where a figure and a price land in the plot.
    struct Geometry {
        let chart: SettingsRangeChart
        let plot: CGRect
        let band: CGFloat
        let lo: Double, hi: Double
        let yLo: Double, yHi: Double
        let freeX: [String: CGFloat]

        init(chart: SettingsRangeChart, size: CGSize, insets: EdgeInsets, band: CGFloat) {
            self.chart = chart
            self.band = band
            plot = CGRect(x: insets.leading, y: insets.top, width: max(10, size.width - insets.leading - insets.trailing),
                          height: max(10, size.height - insets.top - insets.bottom))
            var xs = chart.points.map(\.x).filter { $0 > 0 }
            if let t = chart.together, t.x > 0 { xs.append(t.x) }
            // The red line widens the axis only when it is near the prices; far beyond them it sits at the right edge.
            if let c = chart.ceilingPer1000, c > 0, xs.isEmpty || c <= (xs.max() ?? 0) * 4 { xs.append(c) }
            let mn = xs.min() ?? 0.1, mx = xs.max() ?? 10
            lo = max(0.01, mn / 1.6)
            hi = max(lo * 10, mx * 1.6)
            let ys = chart.points.map(\.y) + chart.kit.compactMap(\.y) + (chart.together.map { [$0.y] } ?? [])
            // The axis keeps to the top 30 points, so one weak route does not flatten the rest; a mark below it sits on
            // the bottom edge, and the chart says so.
            let ymax = ys.max() ?? 100, ymin = max(ys.min() ?? 0, ymax - 30)
            let step = Self.step(ymax - ymin)
            yLo = max(0, ((ymin - step * 0.3) / step).rounded(.down) * step)
            yHi = max(yLo + step, min(100, (ymax / step).rounded(.up) * step))
            // Free marks spread across the band in a fixed order, so they do not sit on one another.
            var fx: [String: CGFloat] = [:]
            for (i, pt) in chart.points.filter({ $0.x == 0 }).sorted(by: { $0.y > $1.y }).enumerated() {
                let f = (Double(i) * 0.618).truncatingRemainder(dividingBy: 1)
                fx[pt.id] = plot.minX + band * CGFloat(0.15 + 0.7 * f)
            }
            freeX = fx
        }

        static func step(_ span: Double) -> Double {
            span > 40 ? 20 : span > 15 ? 10 : span > 6 ? 5 : span > 2 ? 1 : 0.5
        }

        func x(_ v: Double) -> CGFloat {
            let left = plot.minX + band + 8
            let t = (log10(max(v, lo)) - log10(lo)) / (log10(hi) - log10(lo))
            return left + CGFloat(t) * (plot.maxX - left)
        }

        /// Marks below the axis's floor, drawn on the bottom edge.
        var pinned: Bool { chart.points.contains { $0.y < yLo } }

        func y(_ v: Double) -> CGFloat {
            let t = (max(v, yLo) - yLo) / max(1e-9, yHi - yLo)
            return plot.maxY - CGFloat(t) * plot.height
        }

        func center(_ p: SettingsRangeChart.Point) -> CGPoint {
            CGPoint(x: p.x == 0 ? (freeX[p.id] ?? plot.minX + band / 2) : x(p.x), y: y(p.y))
        }

        var yTicks: [Double] {
            let s = Self.step(yHi - yLo)
            return stride(from: yLo, through: yHi + 1e-9, by: s).map { $0 }
        }

        var xTicks: [Double] {
            var out: [Double] = []
            var decade = pow(10, (log10(lo)).rounded(.down))
            while decade <= hi {
                for m in [1.0, 2, 5] where decade * m >= lo && decade * m <= hi { out.append(decade * m) }
                decade *= 10
            }
            // Many decades: the powers of ten alone.
            return out.count > 8 ? out.filter { abs(log10($0).rounded() - log10($0)) < 1e-9 } : out
        }
    }
}

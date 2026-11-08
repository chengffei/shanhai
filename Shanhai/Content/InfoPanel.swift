import SwiftUI

struct InfoPanel: View {
    let controller: GlobeController
    @State private var store = ContentStore()

    var body: some View {
        let geo = controller.geo
        let region = geo.region(controller.selectedRegion)
        let country = geo.country(controller.selectedCountry)
        let content: PlaceContent? = {
            guard let country else { return nil }
            if let region { return store.region(country.a3, id: region.id) }
            return store.country(country.a3)
        }()

        VStack(alignment: .leading, spacing: 0) {
            header(region: region, country: country, content: content)
                .padding(20)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let f = content?.facts { FactsGrid(facts: f, isRegion: region != nil) }
                    if let s = content?.summary, !s.isEmpty { section("简介") { Paragraphs(text: s) } }
                    if let c = content?.culture { section("风土人情") { Paragraphs(text: c.text) } }
                    if let h = content?.history { section("历史") { Paragraphs(text: h.text) } }
                    if let ev = content?.events, !ev.isEmpty { section("发生在这里的大事") { EventList(events: ev) } }
                    if let pp = content?.people, !pp.isEmpty { section(region == nil ? "这个国家的名人" : "从这里走出的名人") { PeopleList(people: pp) } }
                    if content == nil {
                        Text("这个地方还没有整理好的介绍。").foregroundStyle(.secondary)
                    }
                    footer(content: content)
                }
                .padding(20)
                .textSelection(.enabled)
            }
            .scrollIndicators(.never)
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .light)
        .id("\(controller.selectedCountry)-\(controller.selectedRegion)")
    }

    @ViewBuilder
    private func header(region: Region?, country: Country?, content: PlaceContent?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(region?.name ?? country?.name ?? "")
                    .font(.system(size: 26, weight: .bold))
                if let region, let country {
                    Button {
                        controller.select(country: country.id)
                    } label: {
                        Text("\(country.name)  ›").font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .help("看看\(country.name)整个国家")
                } else if let country {
                    Text([country.continentZh, country.nameEn].filter { !$0.isEmpty }.joined(separator: "  ")).font(.callout).foregroundStyle(.secondary)
                }
                if let d = content?.desc, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { controller.clearSelection() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(.quaternary, in: Circle())
            .help("关闭")
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            body()
        }
    }

    @ViewBuilder
    private func footer(content: PlaceContent?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let w = content?.wiki, let url = URL(string: "https://zh.wikipedia.org/wiki/" + (w.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? w)) {
                Link("在维基百科阅读全文", destination: url).font(.footnote)
            }
            Text("内容整理自维基百科与 Wikidata，按 CC BY-SA 4.0 使用。").font(.footnote).foregroundStyle(.tertiary)
        }
    }
}

extension Country {
    var continentZh: String {
        ["Asia": "亚洲", "Europe": "欧洲", "Africa": "非洲", "North America": "北美洲", "South America": "南美洲",
         "Oceania": "大洋洲", "Antarctica": "南极洲", "Seven seas (open ocean)": "海洋"][continent] ?? continent
    }
}

struct Paragraphs: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { _, p in
                Text(String(p)).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FactsGrid: View {
    let facts: PlaceFacts
    let isRegion: Bool
    var body: some View {
        let items: [(String, String)] = [
            (isRegion ? "首府" : "首都", facts.capital ?? ""),
            ("人口", facts.population.map { Self.people($0) + (facts.populationYear.map { "（\($0)）" } ?? "") } ?? ""),
            ("面积", facts.area.map { Self.area($0) } ?? ""),
            ("语言", facts.languages?.joined(separator: "、") ?? ""),
            ("货币", facts.currency ?? ""),
        ].filter { !$0.1.isEmpty }
        if !items.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(items, id: \.0) { k, v in
                    GridRow {
                        Text(k).foregroundStyle(.secondary)
                        Text(v)
                    }
                }
            }
            .font(.callout)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    static func people(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.2f 亿", Double(n) / 1e8) }
        if n >= 10_000 { return String(format: "%.0f 万", Double(n) / 1e4) }
        return "\(n)"
    }

    /// 面积配一个熟悉的参照物
    static func area(_ km2: Int) -> String {
        let s = km2 >= 10_000 ? String(format: "%.1f 万平方公里", Double(km2) / 1e4) : "\(km2) 平方公里"
        let jiangsu = 107_200.0
        let r = Double(km2) / jiangsu
        if r >= 10 { return s + String(format: "，约 %.0f 个江苏", r) }
        if r >= 1.15 { return s + String(format: "，约 %.1f 个江苏", r) }
        if r >= 0.85 { return s + "，和江苏差不多大" }
        if r >= 0.2 { return s + String(format: "，约江苏的 %.0f%%", r * 100) }
        return s
    }
}

struct EventList: View {
    let events: [PlaceEvent]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(events) { e in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(e.year.isEmpty ? "—" : e.year)
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name).font(.callout.weight(.medium))
                        if !e.desc.isEmpty { Text(e.desc).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

struct PeopleList: View {
    let people: [Person]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(people) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(p.name).font(.callout.weight(.semibold))
                        Text(lifespan(p)).font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(p.how == "birth" ? "在这里出生" : "在这里工作")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.05), in: Capsule())
                    }
                    if !p.desc.isEmpty { Text(p.desc).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func lifespan(_ p: Person) -> String {
        switch (p.born.isEmpty, p.died.isEmpty) {
        case (false, false): return "\(p.born) — \(p.died)"
        case (false, true): return "\(p.born)生"
        default: return ""
        }
    }
}

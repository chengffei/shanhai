import Foundation

struct PlaceFacts: Decodable {
    var capital: String?
    var population: Int?
    var populationYear: String?
    var area: Int?
    var languages: [String]?
    var currency: String?
}

struct Snippet: Decodable { var title: String; var text: String }

struct Person: Decodable, Identifiable {
    var q: String
    var name: String
    var desc: String
    var born: String
    var died: String
    var how: String          // birth 出生 / work 在此工作生活
    var id: String { q }
}

struct PlaceEvent: Decodable, Identifiable {
    var q: String
    var name: String
    var desc: String
    var year: String
    var id: String { q }
}

struct PlaceContent: Decodable {
    var desc: String?
    var facts: PlaceFacts?
    var wiki: String?
    var summary: String?
    var history: Snippet?
    var culture: Snippet?
    var people: [Person]?
    var events: [PlaceEvent]?
}

private struct CountryFile: Decodable {
    var country: PlaceContent
    var regions: [String: PlaceContent]
}

/// 按国家懒加载内容文件，最近用过的留在内存
final class ContentStore {
    private var cache: [String: CountryFile] = [:]
    private var order: [String] = []
    private let dir = Bundle.main.resourceURL!.appendingPathComponent("Content")

    private func file(_ a3: String) -> CountryFile? {
        if let f = cache[a3] { return f }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(a3).json")),
              let f = try? JSONDecoder().decode(CountryFile.self, from: data) else { return nil }
        cache[a3] = f
        order.append(a3)
        if order.count > 12 { cache.removeValue(forKey: order.removeFirst()) }
        return f
    }

    func country(_ a3: String) -> PlaceContent? { file(a3)?.country }
    func region(_ a3: String, id: Int) -> PlaceContent? { file(a3)?.regions[String(id)] }
}

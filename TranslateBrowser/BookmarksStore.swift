import Foundation

struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var urlString: String

    init(id: UUID = UUID(), title: String, urlString: String) {
        self.id = id
        self.title = title
        self.urlString = urlString
    }
}

/// Safari-style bookmarks/favorites list, persisted as JSON in UserDefaults. Deliberately not
/// backed by anything fancier (no Core Data, no iCloud sync) since this is a single-device,
/// single-user list of a few dozen URLs at most.
@MainActor
final class BookmarksStore: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []

    private let defaultsKey = "bookmarks.v1"

    init() {
        load()
    }

    func isBookmarked(_ urlString: String) -> Bool {
        bookmarks.contains { $0.urlString == urlString }
    }

    func add(title: String, urlString: String) {
        guard !isBookmarked(urlString) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.append(Bookmark(title: name.isEmpty ? urlString : name, urlString: urlString))
        save()
    }

    func remove(urlString: String) {
        bookmarks.removeAll { $0.urlString == urlString }
        save()
    }

    func remove(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

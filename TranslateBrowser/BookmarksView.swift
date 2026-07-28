import SwiftUI

struct BookmarksView: View {
    @ObservedObject var store: BookmarksStore
    @Environment(\.dismiss) private var dismiss
    var onSelect: (Bookmark) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.bookmarks.isEmpty {
                    ContentUnavailableViewCompat()
                } else {
                    List {
                        ForEach(store.bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(bookmark.urlString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                }
            }
            .navigationTitle("收藏夹")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
                if !store.bookmarks.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
            }
        }
    }
}

/// iOS 17's ContentUnavailableView is convenient but this keeps the deployment target
/// requirement obvious and avoids an availability check at the call site.
private struct ContentUnavailableViewCompat: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "star")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("暂无收藏")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("点击地址栏旁的星标即可收藏当前网页")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

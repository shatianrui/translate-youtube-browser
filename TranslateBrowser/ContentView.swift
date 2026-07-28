import SwiftUI

struct ContentView: View {
    @StateObject private var tabsManager = TabsManager()
    @StateObject private var bookmarksStore = BookmarksStore()
    @FocusState private var addressFocused: Bool
    @State private var showShareSheet = false

    private var activeTab: Tab? { tabsManager.activeTab }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            progressBar
            Divider()
            webViewStack
            Divider()
            bottomToolbar
        }
        .sheet(isPresented: $tabsManager.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: Binding(
            get: { activeTab?.showSubtitleList ?? false },
            set: { activeTab?.showSubtitleList = $0 }
        )) {
            if let activeTab {
                SubtitleListView(tab: activeTab)
            }
        }
        .sheet(isPresented: $tabsManager.showTabsOverview) {
            TabsOverviewView(tabsManager: tabsManager)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = activeTab.flatMap({ URL(string: $0.urlText) }) {
                ShareSheet(items: [url])
            }
        }
        .sheet(item: $bookmarksSheetItem) { _ in
            BookmarksView(store: bookmarksStore) { bookmark in
                activeTab?.load(bookmark.urlString)
            }
        }
    }

    // A tiny wrapper so `.sheet(item:)` can drive the bookmarks list from a plain Bool intent.
    @State private var bookmarksSheetItem: BookmarksSheetToken?
    private struct BookmarksSheetToken: Identifiable { let id = UUID() }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("输入网址或搜索", text: Binding(
                get: { activeTab?.urlText ?? "" },
                set: { activeTab?.urlText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .keyboardType(.URL)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .focused($addressFocused)
            .onSubmit {
                addressFocused = false
                activeTab?.loadFromAddressBar()
            }

            Button {
                activeTab?.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }

            Button {
                tabsManager.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Thin Safari-style loading indicator: a colored bar that grows with estimatedProgress and
    /// disappears once the page (or an already-complete tab) reaches 1.0.
    private var progressBar: some View {
        GeometryReader { geo in
            let progress = activeTab?.estimatedProgress ?? 1
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * progress, height: progress >= 1 ? 0 : 2)
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
        .frame(height: 2)
    }

    /// All tabs stay mounted (just hidden/non-interactive when inactive) so switching tabs
    /// resumes exactly where a page was left — matching Safari suspending rather than discarding
    /// backgrounded tabs — instead of reloading the page from scratch every time.
    private var webViewStack: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(tabsManager.tabs) { tab in
                let isActive = tab.id == tabsManager.activeTabID
                BrowserView(tab: tab, onOpenLinkInNewTab: { url in
                    tabsManager.openInNewTab(url, fromPrivate: tab.isPrivate)
                })
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
            }
            if let activeTab, activeTab.showSubtitlePanel {
                controlBar(for: activeTab)
                    .padding(.trailing, 12)
                    .padding(.top, 10)
            } else if let activeTab {
                Button {
                    activeTab.showSubtitlePanel = true
                } label: {
                    Label("字幕", systemImage: "captions.bubble")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 12)
                .padding(.top, 10)
            }
        }
    }

    /// Small floating status/controls pill. The bilingual caption text itself is rendered by
    /// the injected page script directly inside the YouTube player's own DOM (see
    /// SubtitleExtractor.bilingualOverlayJS), not here — that way it stays visible even when the
    /// player goes fullscreen, which a SwiftUI overlay drawn on top of the WKWebView cannot do.
    private func controlBar(for tab: Tab) -> some View {
        HStack(spacing: 10) {
            if tab.isTranslating {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white)
            }
            Text(tab.statusMessage.isEmpty ? "打开 YouTube 视频页自动提取双语字幕" : tab.statusMessage)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                tab.showSubtitleList = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .disabled(tab.subtitles.isEmpty)
            Button {
                Task { await tab.translateAll() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .disabled(tab.subtitles.isEmpty || tab.isTranslating)
            Button {
                tab.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            Button {
                tab.showSubtitlePanel = false
            } label: {
                Image(systemName: "xmark")
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
    }

    /// Classic Safari bottom toolbar: back, forward, share, bookmark, tabs — five icons, evenly
    /// spaced, tinted dark when the active tab is a private tab.
    private var bottomToolbar: some View {
        let isPrivate = activeTab?.isPrivate ?? false
        return HStack {
            Spacer()
            Button {
                activeTab?.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!(activeTab?.canGoBack ?? false))
            Spacer()
            Button {
                activeTab?.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!(activeTab?.canGoForward ?? false))
            Spacer()
            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(activeTab == nil)
            Spacer()
            Button {
                toggleBookmark()
            } label: {
                Image(systemName: isBookmarked ? "star.fill" : "star")
            }
            .disabled(activeTab == nil)
            Spacer()
            Button {
                bookmarksSheetItem = BookmarksSheetToken()
            } label: {
                Image(systemName: "book")
            }
            Spacer()
            Button {
                tabsManager.showTabsOverview = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "square.on.square")
                    Text("\(tabsManager.tabs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Color.accentColor, in: Circle())
                        .offset(x: 10, y: -8)
                }
            }
            Spacer()
        }
        .font(.system(size: 18))
        .padding(.vertical, 10)
        .background(isPrivate ? Color.black : Color(.secondarySystemBackground))
        .foregroundStyle(isPrivate ? Color.white : Color.primary)
    }

    private var isBookmarked: Bool {
        guard let activeTab else { return false }
        return bookmarksStore.isBookmarked(activeTab.urlText)
    }

    private func toggleBookmark() {
        guard let activeTab else { return }
        if isBookmarked {
            bookmarksStore.remove(urlString: activeTab.urlText)
        } else {
            bookmarksStore.add(title: activeTab.displayTitle, urlString: activeTab.urlText)
        }
    }
}

struct SubtitleListView: View {
    @ObservedObject var tab: Tab
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(tab.subtitles.indices, id: \.self) { i in
                    let sub = tab.subtitles[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatTime(sub.start))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(sub.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let translation = sub.translation {
                            Text(translation)
                                .font(.subheadline)
                        }
                    }
                    .id(i)
                    .background(i == tab.currentIndex ? Color.accentColor.opacity(0.1) : .clear)
                }
                .navigationTitle("字幕列表")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
                .onChange(of: tab.currentIndex) { _, newValue in
                    if let i = newValue {
                        withAnimation { proxy.scrollTo(i, anchor: .center) }
                    }
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

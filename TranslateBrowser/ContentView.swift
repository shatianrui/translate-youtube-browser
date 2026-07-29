import SwiftUI

/// Safari-inspired chrome: full-bleed page, bottom capsule address field, toolbar row.
struct ContentView: View {
    @StateObject private var tabsManager = TabsManager()
    @StateObject private var bookmarksStore = BookmarksStore()
    @FocusState private var addressFocused: Bool
    @State private var showShareSheet = false
    @State private var editingURL = ""

    private var activeTab: Tab? { tabsManager.activeTab }
    private var isPrivate: Bool { activeTab?.isPrivate ?? false }

    var body: some View {
        ZStack {
            (isPrivate ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                webViewStack
                bottomChrome
            }
        }
        .preferredColorScheme(isPrivate ? .dark : nil)
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
                .presentationDetents([.large])
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
        .onChange(of: activeTab?.id) { _, _ in
            addressFocused = false
            editingURL = activeTab?.urlText ?? ""
        }
    }

    @State private var bookmarksSheetItem: BookmarksSheetToken?
    private struct BookmarksSheetToken: Identifiable { let id = UUID() }

    // MARK: - Page

    private var webViewStack: some View {
        ZStack(alignment: .top) {
            ForEach(tabsManager.tabs) { tab in
                let isActive = tab.id == tabsManager.activeTabID
                BrowserView(tab: tab, onOpenLinkInNewTab: { url in
                    tabsManager.openInNewTab(url, fromPrivate: tab.isPrivate)
                })
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
            }

            // Thin Safari-style progress line under the status area
            progressBar
                .frame(maxHeight: .infinity, alignment: .top)

            if let activeTab {
                subtitleHUD(for: activeTab)
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let progress = activeTab?.estimatedProgress ?? 1
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: max(0, geo.size.width * progress), height: progress >= 0.999 ? 0 : 2)
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private func subtitleHUD(for tab: Tab) -> some View {
        // Quiet by default — only surface failures / blocks (with original meaning).
        let msg = tab.statusMessage
        let showChip = !msg.isEmpty && (
            msg.contains("拦截")
            || msg.contains("失败")
            || msg.contains("无法")
            || msg.contains("错误")
            || msg.contains("API Key")
        )

        return Group {
            if showChip {
                HStack(spacing: 8) {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                    if msg.contains("拦截") || msg.contains("失败") {
                        Button { tab.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .allowsHitTesting(true)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.statusMessage)
    }

    // MARK: - Safari bottom chrome

    private var bottomChrome: some View {
        VStack(spacing: 8) {
            addressCapsule
            toolbarRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Divider()
                }
        }
    }

    /// Safari-like capsule: lock + host when idle; editable URL when focused.
    private var addressCapsule: some View {
        HStack(spacing: 8) {
            if addressFocused {
                TextField("搜索或输入网站", text: $editingURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .font(.body)
                    .onSubmit { commitAddress() }
            } else {
                Button {
                    editingURL = activeTab?.urlText ?? ""
                    addressFocused = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: compactIsSecure ? "lock.fill" : "globe")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(compactHost)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }

            if addressFocused {
                Button("取消") {
                    addressFocused = false
                }
                .font(.subheadline)
            } else {
                Button {
                    if (activeTab?.estimatedProgress ?? 1) < 0.999 {
                        activeTab?.stopLoading()
                    } else {
                        activeTab?.reload()
                    }
                } label: {
                    Image(systemName: (activeTab?.estimatedProgress ?? 1) < 0.999 ? "xmark" : "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                Button {
                    tabsManager.showSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let tab = activeTab {
                        Button {
                            tab.showSubtitleList = true
                        } label: {
                            Label("字幕列表", systemImage: "list.bullet")
                        }
                        .disabled(tab.subtitles.isEmpty)
                        Button {
                            Task { await tab.translateAll() }
                        } label: {
                            Label("重新翻译", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(tab.subtitles.isEmpty || tab.isTranslating)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(isPrivate ? Color.white.opacity(0.12) : Color(.tertiarySystemFill))
        )
    }

    private var compactHost: String {
        guard let raw = activeTab?.urlText, let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return "搜索或输入网站"
        }
        return host.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
    }

    private var compactIsSecure: Bool {
        (activeTab?.urlText ?? "").hasPrefix("https://")
    }

    private func commitAddress() {
        addressFocused = false
        guard let tab = activeTab else { return }
        tab.urlText = editingURL
        tab.loadFromAddressBar()
    }

    private var toolbarRow: some View {
        HStack {
            toolbarButton("chevron.left", disabled: !(activeTab?.canGoBack ?? false)) {
                activeTab?.goBack()
            }
            Spacer()
            toolbarButton("chevron.right", disabled: !(activeTab?.canGoForward ?? false)) {
                activeTab?.goForward()
            }
            Spacer()
            toolbarButton("square.and.arrow.up", disabled: activeTab == nil) {
                showShareSheet = true
            }
            Spacer()
            toolbarButton(isBookmarked ? "book.fill" : "book", disabled: activeTab == nil) {
                // Long-press style: tap toggles bookmark; use bookmarks list via hold alternative —
                // Safari puts bookmark toggle here; we open the list on a second icon via tabs.
                // Keep Safari mapping: open bookmarks library.
                bookmarksSheetItem = BookmarksSheetToken()
            }
            .contextMenu {
                Button {
                    toggleBookmark()
                } label: {
                    Label(isBookmarked ? "删除书签" : "添加书签", systemImage: isBookmarked ? "star.slash" : "star")
                }
                Button {
                    bookmarksSheetItem = BookmarksSheetToken()
                } label: {
                    Label("书签列表", systemImage: "book")
                }
            }
            Spacer()
            Button {
                tabsManager.showTabsOverview = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(isPrivate ? Color.white : Color.accentColor, lineWidth: 1.8)
                        .frame(width: 20, height: 20)
                    Text("\(min(tabsManager.tabs.count, 99))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isPrivate ? Color.white : Color.accentColor)
                }
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func toolbarButton(_ systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : (isPrivate ? Color.white : Color.accentColor))
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatTime(sub.start))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(sub.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let translation = sub.translation, !translation.isEmpty {
                            Text(translation)
                                .font(.body)
                        }
                    }
                    .id(i)
                    .listRowBackground(i == tab.currentIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                }
                .navigationTitle("双语字幕")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
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

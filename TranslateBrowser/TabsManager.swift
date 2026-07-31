import Foundation
import Combine
import SwiftUI

/// Owns every open tab, like Safari's tab list. Tabs are kept alive (their WKWebView included)
/// even while not the active one, so switching back to a tab resumes it rather than reloading —
/// same as Safari suspending rather than discarding a backgrounded tab.
@MainActor
final class TabsManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var activeTabID: Tab.ID?
    @Published var showSettings = false
    @Published var showTabsOverview = false

    private static let defaultURL = "https://m.youtube.com/"

    // ContentView only holds this manager as its @StateObject, not the individual Tab objects,
    // so a Tab's own @Published changes (progress, subtitles, canGoBack, ...) wouldn't otherwise
    // trigger a re-render. Forwarding each tab's objectWillChange up through this object's own
    // publisher is what makes the active tab's UI (address bar, progress bar, toolbar) reactive.
    private var tabChangeForwarders: [Tab.ID: AnyCancellable] = [:]

    init() {
        _ = newTab()
    }

    var activeTab: Tab? {
        tabs.first(where: { $0.id == activeTabID })
    }

    var normalTabs: [Tab] { tabs.filter { !$0.isPrivate } }
    var privateTabs: [Tab] { tabs.filter { $0.isPrivate } }

    @discardableResult
    func newTab(urlString: String = TabsManager.defaultURL, isPrivate: Bool = false, makeActive: Bool = true) -> Tab {
        let tab = Tab(urlText: urlString, isPrivate: isPrivate)
        tab.tabsManager = self
        tabs.append(tab)
        tabChangeForwarders[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if makeActive {
            activeTabID = tab.id
        }
        return tab
    }

    func closeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasActive = activeTabID == tab.id
        tabs.remove(at: index)
        tabChangeForwarders.removeValue(forKey: tab.id)
        guard wasActive else { return }
        if tabs.isEmpty {
            newTab()
        } else {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func selectTab(_ tab: Tab) {
        activeTabID = tab.id
    }

    /// Opens a link tapped/long-pressed inside any tab's page into a fresh tab of the same
    /// privacy mode (private-tab links open as private tabs too, like Safari).
    func openInNewTab(_ url: URL, fromPrivate: Bool) {
        newTab(urlString: url.absoluteString, isPrivate: fromPrivate)
    }
}

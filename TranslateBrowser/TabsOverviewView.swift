import SwiftUI
import UIKit

/// Safari-style tab switcher: a grid of open tabs with a Normal/Private segmented control at the
/// top (private tabs render with a dark card to match Safari's private-mode tint), tap a card to
/// switch to it, tap its X to close it, and a "+" to open a fresh tab in whichever mode is shown.
struct TabsOverviewView: View {
    @ObservedObject var tabsManager: TabsManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingPrivate = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var visibleTabs: [Tab] {
        showingPrivate ? tabsManager.privateTabs : tabsManager.normalTabs
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if visibleTabs.isEmpty {
                    Text(showingPrivate ? "没有隐私标签页" : "没有标签页")
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleTabs) { tab in
                            TabCard(
                                tab: tab,
                                isActive: tab.id == tabsManager.activeTabID,
                                onSelect: {
                                    tabsManager.selectTab(tab)
                                    dismiss()
                                },
                                onClose: { tabsManager.closeTab(tab) }
                            )
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("标签页")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        tabsManager.newTab(isPrivate: showingPrivate)
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("模式", selection: $showingPrivate) {
                        Text("标签页").tag(false)
                        Text("隐私浏览").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: Tab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tab.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(tab.isPrivate ? Color.white : Color.primary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tab.isPrivate ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .padding(8)

            Spacer()

            Image(systemName: tab.isPrivate ? "eye.slash" : "globe")
                .font(.system(size: 28))
                .foregroundStyle(tab.isPrivate ? Color.white.opacity(0.6) : Color.secondary)

            Spacer()
        }
        .frame(height: 130)
        .background(tab.isPrivate ? Color.black : Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Color.accentColor : .clear, lineWidth: 3)
        )
        .onTapGesture(perform: onSelect)
    }
}

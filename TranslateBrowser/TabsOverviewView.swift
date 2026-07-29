import SwiftUI
import UIKit

/// Safari-style tab switcher with Normal / Private segments.
struct TabsOverviewView: View {
    @ObservedObject var tabsManager: TabsManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingPrivate = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    private var visibleTabs: [Tab] {
        showingPrivate ? tabsManager.privateTabs : tabsManager.normalTabs
    }

    var body: some View {
        NavigationStack {
            ZStack {
                (showingPrivate ? Color.black : Color(.systemGroupedBackground))
                    .ignoresSafeArea()

                ScrollView {
                    if visibleTabs.isEmpty {
                        ContentUnavailableView(
                            showingPrivate ? "没有隐私标签页" : "没有打开的标签页",
                            systemImage: showingPrivate ? "eyeglasses" : "square.on.square",
                            description: Text(showingPrivate ? "在隐私模式下浏览不会保存历史记录" : "点右上角 + 打开新标签页")
                        )
                        .padding(.top, 80)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
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
                        .padding(16)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        tabsManager.newTab(isPrivate: showingPrivate)
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("模式", selection: $showingPrivate) {
                        Text("标签页").tag(false)
                        Text("隐私").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .toolbarBackground(showingPrivate ? .visible : .automatic, for: .navigationBar)
            .toolbarColorScheme(showingPrivate ? .dark : nil, for: .navigationBar)
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
            HStack(spacing: 6) {
                Image(systemName: tab.isPrivate ? "eyeglasses" : "globe")
                    .font(.caption2)
                    .foregroundStyle(tab.isPrivate ? Color.white.opacity(0.7) : Color.secondary)
                Text(tab.displayTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(tab.isPrivate ? Color.white : Color.primary)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tab.isPrivate ? Color.white.opacity(0.7) : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ZStack {
                (tab.isPrivate ? Color(white: 0.12) : Color(.secondarySystemGroupedBackground))
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(tab.isPrivate ? Color.white.opacity(0.35) : Color.secondary.opacity(0.5))
                    Text(hostLabel)
                        .font(.caption2)
                        .foregroundStyle(tab.isPrivate ? Color.white.opacity(0.45) : Color.secondary)
                        .lineLimit(1)
                }
                .padding(8)
            }
            .frame(height: 110)
        }
        .background(tab.isPrivate ? Color(white: 0.08) : Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isActive ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isActive ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(tab.isPrivate ? 0 : 0.06), radius: 8, y: 3)
        .onTapGesture(perform: onSelect)
    }

    private var hostLabel: String {
        URL(string: tab.urlText)?.host?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
            ?? tab.urlText
    }
}

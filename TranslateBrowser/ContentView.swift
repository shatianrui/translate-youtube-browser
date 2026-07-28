import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = BrowserViewModel()
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            ZStack(alignment: .topTrailing) {
                BrowserView(viewModel: viewModel)
                if viewModel.showSubtitlePanel {
                    controlBar
                        .padding(.trailing, 12)
                        .padding(.top, 10)
                }
            }
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $viewModel.showSubtitleList) {
            SubtitleListView(viewModel: viewModel)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.goBack) {
                Image(systemName: "chevron.left")
            }
            Button(action: viewModel.goForward) {
                Image(systemName: "chevron.right")
            }
            Button(action: viewModel.reload) {
                Image(systemName: "arrow.clockwise")
            }

            TextField("输入网址或搜索", text: $viewModel.urlText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .focused($addressFocused)
                .onSubmit {
                    addressFocused = false
                    viewModel.loadFromAddressBar()
                }

            Button {
                viewModel.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Small floating status/controls pill. The bilingual caption text itself is rendered by
    /// the injected page script directly inside the YouTube player's own DOM (see
    /// SubtitleExtractor.bilingualOverlayJS), not here — that way it stays visible even when the
    /// player goes fullscreen, which a SwiftUI overlay drawn on top of the WKWebView cannot do.
    private var controlBar: some View {
        HStack(spacing: 10) {
            if viewModel.isTranslating {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white)
            }
            Text(viewModel.statusMessage.isEmpty ? "打开 YouTube 视频页自动提取双语字幕" : viewModel.statusMessage)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                viewModel.showSubtitleList = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .disabled(viewModel.subtitles.isEmpty)
            Button {
                Task { await viewModel.translateAll() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .disabled(viewModel.subtitles.isEmpty || viewModel.isTranslating)
            Button {
                viewModel.showSubtitlePanel = false
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
}

struct SubtitleListView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(viewModel.subtitles.indices, id: \.self) { i in
                    let sub = viewModel.subtitles[i]
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
                    .background(i == viewModel.currentIndex ? Color.accentColor.opacity(0.1) : .clear)
                }
                .navigationTitle("字幕列表")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
                .onChange(of: viewModel.currentIndex) { _, newValue in
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

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = BrowserViewModel()
    @State private var showSettings = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            if viewModel.isLoading {
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
            WebView(webView: viewModel.webView)
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay(alignment: .bottom) { statusPill }
            toolbar
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                TextField("输入网址或搜索", text: $viewModel.addressText)
                    .focused($addressFocused)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        addressFocused = false
                        viewModel.submitAddress()
                    }
                if !viewModel.addressText.isEmpty && addressFocused {
                    Button {
                        viewModel.addressText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if viewModel.isLoading {
                Button {
                    viewModel.webView.stopLoading()
                } label: {
                    Image(systemName: "xmark")
                }
            } else {
                Button {
                    viewModel.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch viewModel.status {
        case .idle:
            EmptyView()
        case .translating(let done, let total):
            pill(text: "字幕翻译中 \(done)/\(total)", systemImage: "captions.bubble", color: .blue)
        case .finished(let total):
            pill(text: "已翻译 \(total) 条字幕", systemImage: "checkmark.circle", color: .green)
        case .failed(let message):
            pill(text: message, systemImage: "exclamationmark.triangle", color: .orange)
        }
    }

    private func pill(text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .foregroundStyle(color)
            .padding(.bottom, 12)
            .padding(.horizontal, 16)
    }

    private var toolbar: some View {
        HStack {
            Button {
                viewModel.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!viewModel.canGoBack)
            Spacer()
            Button {
                viewModel.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.canGoForward)
            Spacer()
            Button {
                viewModel.goHome()
            } label: {
                Image(systemName: "play.rectangle")
            }
            Spacer()
            if let url = viewModel.currentURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
            } else {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
        .font(.title3)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.bar)
    }
}

#Preview {
    ContentView()
}

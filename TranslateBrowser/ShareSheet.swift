import SwiftUI
import UIKit

/// Thin wrapper around UIActivityViewController so the toolbar's share button can present the
/// same system share sheet Safari uses (Messages, Mail, Copy, Save to Files, etc).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

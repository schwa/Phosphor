import SwiftUI

/// Shown when ``PhosphorView`` failed to initialize its Metal runtime
/// (no GPU, allocation failure, etc.).
struct PhosphorErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Phosphor Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .font(.system(.body, design: .monospaced))
        }
    }
}

#Preview("Error") {
    PhosphorErrorView(message: "No Metal device available")
        .frame(width: 480, height: 240)
}

import SwiftUI

/// Placeholder shown when the runtime isn't ready yet (no parsed env, or the
/// first frame hasn't fired). Plain black so it blends with the rest of the
/// chrome.
struct PhosphorLoadingView: View {
    var body: some View {
        Color.black
    }
}

#Preview("Loading") {
    PhosphorLoadingView()
        .frame(width: 480, height: 240)
}

import PhosphorSupport
import SwiftUI

struct ContentView: View {
    var body: some View {
        if let view = PhosphorView(source: GameOfLife.source) {
            view.frame(minWidth: 640, minHeight: 480)
        } else {
            Text("Failed to parse Phosphor front-matter.")
        }
    }
}

#Preview {
    ContentView()
}

import PhosphorSupport
import SwiftUI

struct ContentView: View {
    var body: some View {
        PhosphorView(
            environment: GameOfLife.environment,
            source: GameOfLife.source
        )
        .frame(minWidth: 640, minHeight: 480)
    }
}

#Preview {
    ContentView()
}

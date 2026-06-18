import PhosphorSupport
import SwiftUI

struct ContentView: View {
    @State private var selected: Demo = Demo.all.first!

    var body: some View {
        HSplitView {
            codePane
                .frame(minWidth: 280, idealWidth: 420)
            previewPane
                .frame(minWidth: 360, idealWidth: 640)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Demo", selection: $selected) {
                    ForEach(Demo.all) { demo in
                        Text(demo.name).tag(demo)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 180)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    @ViewBuilder
    private var codePane: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(verbatim: selected.source)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.textBackgroundColor))
    }

    @ViewBuilder
    private var previewPane: some View {
        if let view = PhosphorView(source: selected.source) {
            view
        } else {
            ContentUnavailableView {
                Label("Failed to parse demo", systemImage: "exclamationmark.triangle")
            } description: {
                Text(selected.name)
            }
        }
    }
}

#Preview {
    ContentView()
}

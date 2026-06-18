import PhosphorSupport
import SwiftUI

struct ContentView: View {
    @State private var selected: Demo = Demo.all.first!
    @State private var showHeader: Bool = false

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
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    showHeader.toggle()
                } label: {
                    Label("Show Phosphor.h", systemImage: "doc.text.magnifyingglass")
                }
                .popover(isPresented: $showHeader, arrowEdge: .top) {
                    headerPopover
                }
            }
            .padding(8)
            .background(Color(.windowBackgroundColor))

            Divider()

            ScrollView([.horizontal, .vertical]) {
                MetalSourceView(text: selected.source)
                    .padding(12)
            }
            .background(Color(.textBackgroundColor))
        }
    }

    @ViewBuilder
    private var headerPopover: some View {
        let env = selected.parsed.environment ?? PhosphorEnvironment(output: "image")
        let header = PhosphorHeader.source(for: env)
        ScrollView([.horizontal, .vertical]) {
            MetalSourceView(text: header)
                .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 600, minHeight: 320, idealHeight: 480)
    }

    @ViewBuilder
    private var previewPane: some View {
        if let view = PhosphorView(parsed: selected.parsed) {
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

import PhosphorSupport
import SwiftUI

/// Top-level view for an open `.metal` document.
///
/// Same split-pane layout as the demo browser: source on the left, preview
/// on the right. Read-only for now; live editing is a separate feature.
struct PhosphorDocumentView: View {
    @Bindable var document: PhosphorMetalDocument
    @State private var showHeader: Bool = false
    @State private var showGenerate: Bool = false

    var body: some View {
        HSplitView {
            codePane
                .frame(minWidth: 280, idealWidth: 420)
            previewPane
                .frame(minWidth: 360, idealWidth: 640)
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showGenerate = true
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
            }
        }
        .sheet(isPresented: $showGenerate) {
            GeneratePanel(isPresented: $showGenerate, document: document)
                .frame(minWidth: 480, minHeight: 240)
        }
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

            MetalSourceView(text: $document.text)
                .padding(12)
                .background(Color(.textBackgroundColor))
                .onChange(of: document.text) { _, _ in
                    document.refreshParsed()
                }
        }
    }

    @ViewBuilder
    private var headerPopover: some View {
        let env = document.parsed.environment ?? PhosphorEnvironment(output: "image")
        let header = PhosphorHeader.source(for: env)
        ScrollView([.horizontal, .vertical]) {
            MetalSourceView(text: header)
                .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 600, minHeight: 320, idealHeight: 480)
    }

    @ViewBuilder
    private var previewPane: some View {
        if let view = PhosphorView(parsed: document.parsed) {
            view
        } else {
            ContentUnavailableView {
                Label("No front-matter", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("This file has no /* phosphor:environment ... */ block, or it failed to parse.")
            }
        }
    }
}

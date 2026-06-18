import PhosphorSupport
import SwiftUI

/// Sheet that prompts the user for a natural-language description, runs
/// ``ShaderGenerator``, and replaces the document's text on success.
struct GeneratePanel: View {
    @Binding var isPresented: Bool
    @Bindable var document: PhosphorMetalDocument

    @State private var prompt: String = ""
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Generate Shader", systemImage: "sparkles")
                .font(.headline)

            Text("Describe the effect you want, e.g. \"a swirling galaxy\" or \"falling Matrix code\".")
                .foregroundStyle(.secondary)
                .font(.callout)

            TextField("Prompt", text: $prompt, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.roundedBorder)
                .disabled(isGenerating)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .disabled(isGenerating)

                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Generate")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560)
    }

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let source = try await ShaderGenerator().generate(prompt: prompt)
            document.text = source
            document.refreshParsed()
            isPresented = false
        } catch {
            errorMessage = "\(error)"
        }
    }
}

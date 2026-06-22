import PhosphorSupport
import SwiftUI

/// Inspector panel that prompts the user for a natural-language description,
/// runs ``ShaderGenerator``, and replaces the document's text on success.
///
/// Non-modal: lives in the inspector so the user can iterate while watching
/// the live preview. Reports generation start/stop via ``onGeneratingChange``
/// so the host can keep the inspector open.
struct GeneratePanel: View {
    @Binding var text: String
    let parsed: ParsedPhosphorSource
    let isUntouchedTemplate: Bool
    let onTextChange: () -> Void
    var onGeneratingChange: (Bool) -> Void = { _ in }

    @Environment(\.textMutator) private var textMutator

    @State private var prompt: String = ""
    @State private var isGenerating: Bool = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @AppStorage("phosphor.generation.model") private var modelRawValue: String = GenerationModel.onDevice.rawValue

    private var selectedModel: GenerationModel {
        GenerationModel(rawValue: modelRawValue) ?? .onDevice
    }

    private var isModifying: Bool {
        parsed.hasFrontMatter && !isUntouchedTemplate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(isModifying ? "Modify Shader" : "Generate Shader", systemImage: "sparkles")
                .font(.headline)

            Text(isModifying
                    ? "Describe how to change the current shader, e.g. \"make it pulse with the time\" or \"add a red tint\"."
                    : "Describe the effect you want, e.g. \"a swirling galaxy\" or \"falling Matrix code\".")
                .foregroundStyle(.secondary)
                .font(.callout)

            TextField("Prompt", text: $prompt, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.roundedBorder)
                .disabled(isGenerating)

            HStack {
                Text("Model:")
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $modelRawValue) {
                    ForEach(GenerationModel.all, id: \.rawValue) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(isGenerating)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isModifying ? "Modify" : "Generate")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
            }
        }
        .padding(20)
    }

    private func generate() async {
        isGenerating = true
        onGeneratingChange(true)
        errorMessage = nil
        statusMessage = nil
        defer {
            isGenerating = false
            onGeneratingChange(false)
            statusMessage = nil
        }

        do {
            let adapter = try FoundationModelAdapter.make(model: selectedModel)
            let source = try await ShaderGenerator(model: adapter).generate(
                prompt: prompt,
                existingSource: isModifying ? text : ""
            ) { phase in
                statusMessage = phaseMessage(phase)
            }
            if let textMutator {
                textMutator.apply(source, actionName: isModifying ? "Modify Shader" : "Generate Shader")
            } else {
                text = source
                onTextChange()
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func phaseMessage(_ phase: GenerationPhase) -> String {
        switch phase {
        case .generating:
            return "Generating…"

        case .retrying:
            return "Compile failed, retrying with feedback…"
        }
    }
}

#Preview("Fresh") {
    GeneratePanel(
        text: .constant(""),
        parsed: ParsedPhosphorSource(source: ""),
        isUntouchedTemplate: true
    ) {}
}

#Preview("Modify") {
    GeneratePanel(
        text: .constant("// existing kernel\nkernel void image() {}"),
        parsed: ParsedPhosphorSource(source: ""),
        isUntouchedTemplate: false
    ) {}
}

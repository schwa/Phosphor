import SwiftUI
import FoundationModels

struct ShaderGeneratorView: View {
    @State private var isPromptPresented: Bool = false
    @State private var isLoading: Bool = false
    @State private var prompt: String = "Make a shader function that draws a circle!"

    var callback: (String) -> Void

    var body: some View {

        Group {
            TextEditor(text: $prompt)
            if isLoading {
                ProgressView()
            }
            else {
                HStack {
                    Spacer()
                    Button("Generate") {
                        Task {
                            do {
                                isLoading = true
                                let session = LanguageModelSession.metalShaderSession
                                let response = try await session.respond(
                                    to: prompt,
                                    generating: GenerableShader.self
                                )
                                isLoading = false
                                callback(response.content.source)
                            }
                            catch {
                                print("Error generating shader: \(error)")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }
}

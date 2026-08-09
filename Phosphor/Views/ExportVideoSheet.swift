import AVFoundation
import PhosphorCompile
import PhosphorModel
import PhosphorVideo
import SwiftUI
import UniformTypeIdentifiers

/// Collects export settings, then renders and encodes with a progress bar.
///
/// The render is offline, so it runs as fast as the machine allows rather
/// than in real time, and the preview keeps playing untouched.
struct ExportVideoSheet: View {
    let parsed: ParsedPhosphorSource
    let assets: [String: PhosphorAsset]
    let uniformValues: [String: UniformValue]

    @Environment(\.dismiss) private var dismiss

    @AppStorage("phosphor.export.video.width") private var width: Int = 1_920
    @AppStorage("phosphor.export.video.height") private var height: Int = 1_080
    @AppStorage("phosphor.export.video.frameRate") private var frameRate: Int = 60
    @AppStorage("phosphor.export.video.duration") private var duration: Double = 5
    @AppStorage("phosphor.export.video.useHEVC") private var useHEVC: Bool = false

    @State private var progress: Double?
    @State private var task: Task<Void, Never>?
    @State private var errorMessage: String?

    private var settings: VideoExporter.Settings {
        VideoExporter.Settings(
            size: CGSize(width: width, height: height),
            frameRate: frameRate,
            startTime: 0,
            duration: duration,
            codec: useHEVC ? .hevc : .h264
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Video")
                .font(.headline)

            Form {
                LabeledContent("Size") {
                    HStack {
                        TextField("Width", value: $width, format: .number)
                            .frame(width: 80)
                        Text(verbatim: "×")
                        TextField("Height", value: $height, format: .number)
                            .frame(width: 80)
                    }
                }
                Picker("Frame Rate", selection: $frameRate) {
                    ForEach([24, 30, 60, 120], id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
                LabeledContent("Duration") {
                    HStack {
                        TextField("Duration", value: $duration, format: .number)
                            .frame(width: 80)
                        Text("seconds")
                    }
                }
                Picker("Codec", selection: $useHEVC) {
                    Text("H.264").tag(false)
                    Text("HEVC").tag(true)
                }
                LabeledContent("Frames", value: "\(settings.frameCount)")
            }
            .formStyle(.grouped)
            .disabled(progress != nil)

            if let progress {
                ProgressView(value: progress) {
                    Text("Rendering…")
                }
                .progressViewStyle(.linear)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export…") {
                    chooseDestinationAndExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(progress != nil)
            }
        }
        .padding()
        .frame(width: 420)
        .onDisappear { task?.cancel() }
    }

    private func chooseDestinationAndExport() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.quickTimeMovie]
        panel.nameFieldStringValue = "Shader.mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
        #endif
    }

    private func export(to url: URL) {
        errorMessage = nil
        progress = 0
        let settings = settings
        let parsed = parsed
        let assets = assets
        let uniformValues = uniformValues
        task = Task {
            do {
                try await VideoExporter().export(
                    parsed: parsed,
                    assets: assets,
                    uniformValues: uniformValues,
                    to: url,
                    settings: settings
                ) { value in
                    Task { @MainActor in progress = value }
                }
                await MainActor.run { dismiss() }
            } catch is CancellationError {
                await MainActor.run { progress = nil }
            } catch {
                await MainActor.run {
                    progress = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    ExportVideoSheet(
        parsed: ParsedPhosphorSource(source: PhosphorStarterTemplate.source),
        assets: [:],
        uniformValues: [:]
    )
}

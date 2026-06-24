import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// Lists front-matter / validation / compile diagnostics for the current
/// document. Renders nothing when there are no diagnostics.
struct DiagnosticsView: View {
    let diagnostics: [PhosphorDiagnostic]

    var body: some View {
        if !diagnostics.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(diagnostics, id: \.self) { diagnostic in
                        Text(verbatim: Self.diagnosticString(diagnostic))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(.red.opacity(0.85), in: .rect(cornerRadius: 6))
            .frame(maxWidth: 720, maxHeight: 400)
            .padding(8)
        }
    }

    private static func diagnosticString(_ diagnostic: PhosphorDiagnostic) -> String {
        switch diagnostic {
        case .frontMatterParse(let msg, let line):
            return "frontmatter: \(msg)\(line.map { " (line \($0))" } ?? "")"

        case .unknownResource(let id, let context):
            return "unknown resource '\(id)' in \(context)"

        case .duplicateResource(let id):
            return "duplicate resource '\(id)'"

        case .duplicatePass(let id):
            return "duplicate pass '\(id)'"

        case .duplicateBinding(let name, let pass):
            return "duplicate binding '\(name)' in pass '\(pass)'"

        case .readWriteHazard(let pass, let resource):
            return "read/write hazard: pass '\(pass)' reads + writes '\(resource)'"

        case .passHasNoOutput(let pass):
            return "pass '\(pass)' declares no write binding"

        case .missingOutput(let id):
            return "missing output resource '\(id)'"

        case .compile(let error):
            return "compile error in '\(error.passID)':\n\(error.rawError)"

        case .missingAsset(let name, let resource):
            return "asset '\(name)' missing (referenced by resource '\(resource)') — texture zero-filled"

        case .imageTextureCannotPingPong(let id):
            return "image texture '\(id)' cannot be ping-pong (swap must be \"none\")"
        }
    }
}

#Preview("Diagnostics") {
    DiagnosticsView(diagnostics: [
        .missingOutput("image"),
        .duplicatePass("render")
    ])
    .frame(width: 480, height: 240)
}

#Preview("Empty") {
    DiagnosticsView(diagnostics: [])
        .frame(width: 480, height: 240)
        .background(.black)
}

import PhosphorSupport
import SwiftUI

/// Inspector tab that lets the user edit the parsed configuration's textures,
/// passes, uniforms, and top-level fields (output, flipY). Mutations go
/// into a draft `PhosphorConfiguration`; Apply validates and splices the
/// re-encoded TOML back into the source text.
struct PhosphorConfigurationEditorView: View {
    let parsed: ParsedPhosphorSource
    @Binding var text: String
    @Environment(\.textMutator) private var textMutator

    @State private var draft: PhosphorConfiguration?
    @State private var diagnostics: [PhosphorDiagnostic] = []
    @State private var applyError: String?

    var body: some View {
        Group {
            if let draft = Binding($draft) {
                ConfigurationEditorView(
                    draft: draft,
                    diagnostics: diagnostics,
                    applyError: applyError,
                    onApply: { apply(config: draft.wrappedValue) },
                    onRevert: { syncDraftFromParsed() }
                )
            } else {
                ContentUnavailableView(
                    "No Front-Matter",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This document doesn't have a parseable /* phosphor:environment ... */ block.")
                )
            }
        }
        .onChange(of: parsed) { _, _ in
            syncDraftFromParsed()
        }
        .onAppear {
            syncDraftFromParsed()
        }
    }

    /// Reset the draft to whatever the document's parsed configuration is
    /// currently showing. Called on appear and when the parsed source
    /// changes externally (e.g. user edits the TOML directly).
    private func syncDraftFromParsed() {
        draft = parsed.configuration
        diagnostics = parsed.diagnostics
        applyError = nil
    }

    /// Validate the draft, then splice its re-encoded TOML back into the
    /// source. Refuses to apply if validation produces fatal diagnostics.
    private func apply(config: PhosphorConfiguration) {
        let validation = validate(config)
        let fatal = validation.filter(\.isFatal)
        if !fatal.isEmpty {
            diagnostics = validation
            applyError = nil
            return
        }
        do {
            let body = try FrontMatterFormatter.encodeBody(config)
            let wrapped = FrontMatterFormatter.wrapFrontMatter(body: body)

            // Splice: replace the existing /* phosphor:environment ... */
            // block, preserving prefix (prompt comments etc.) and suffix
            // (the kernel body and everything below).
            let openMarker = "/* phosphor:environment"
            guard let openRange = text.range(of: openMarker),
                  let closeRange = text.range(of: "*/", range: openRange.upperBound..<text.endIndex) else {
                applyError = "Couldn't find front-matter block to replace."
                return
            }
            var updated = text
            updated.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: wrapped)
            if let textMutator {
                textMutator.apply(updated, actionName: "Edit Configuration")
            } else {
                text = updated
            }
            diagnostics = validation
            applyError = nil
        } catch {
            applyError = "\(error)"
        }
    }
}

/// The actual editor surface, parametrized over a non-nil draft binding so
/// child rows can bind to specific fields without optional unwrapping.
private struct ConfigurationEditorView: View {
    @Binding var draft: PhosphorConfiguration
    let diagnostics: [PhosphorDiagnostic]
    let applyError: String?
    let onApply: () -> Void
    let onRevert: () -> Void

    var body: some View {
        Form {
            Section("Top-Level") {
                Picker("Output", selection: $draft.output) {
                    ForEach(draft.textures, id: \.id) { texture in
                        Text(texture.id.raw).tag(texture.id)
                    }
                }
                Toggle("Flip Y", isOn: $draft.flipY)
            }

            Section("Textures") {
                TexturesEditor(textures: $draft.textures)
            }

            Section("Passes") {
                PassesEditor(passes: $draft.passes, textures: draft.textures)
            }

            Section("Uniforms") {
                UniformsEditor(uniforms: $draft.uniforms)
            }

            if !diagnostics.isEmpty {
                Section("Validation") {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(verbatim: String(describing: diagnostic))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(diagnostic.isFatal ? .red : .secondary)
                    }
                }
            }

            if let applyError {
                Section {
                    Text(applyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Revert", action: onRevert)
                Spacer()
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.background.secondary)
        }
    }
}

// MARK: - Textures

private struct TexturesEditor: View {
    @Binding var textures: [PhosphorSupport.Texture]

    var body: some View {
        ForEach($textures, id: \.id) { $texture in
            TextureRow(texture: $texture)
        }
        Button {
            textures.append(uniqueNewTexture(existing: textures))
        } label: {
            Label("Add Texture", systemImage: "plus")
        }
    }

    private func uniqueNewTexture(existing: [PhosphorSupport.Texture]) -> PhosphorSupport.Texture {
        let usedIDs = Set(existing.map(\.id))
        var name = "texture"
        var counter = 2
        while usedIDs.contains(ResourceID(name)) {
            name = "texture\(counter)"
            counter += 1
        }
        return PhosphorSupport.Texture(id: ResourceID(name))
    }
}

private struct TextureRow: View {
    @Binding var texture: PhosphorSupport.Texture

    var body: some View {
        DisclosureGroup(texture.id.raw) {
            ResourceIDField(label: "ID", id: $texture.id)
            Picker("Format", selection: $texture.format) {
                ForEach(PhosphorPixelFormat.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            TextureSizeField(size: $texture.size)
            Picker("Swap", selection: $texture.swap) {
                Text("None").tag(SwapTiming.none)
                Text("End of Frame").tag(SwapTiming.endOfFrame)
                Text("Immediate").tag(SwapTiming.immediate)
            }
            TextureInitField(init: $texture.initialContents)
        }
    }
}

private struct TextureSizeField: View {
    @Binding var size: TextureSize

    @State private var kind: SizeKind = .drawable
    @State private var width: Int = 256
    @State private var height: Int = 256
    @State private var scale: Float = 1.0

    private enum SizeKind: String, CaseIterable {
        case drawable
        case fixed
        case scaled
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Size", selection: $kind) {
                Text("Drawable").tag(SizeKind.drawable)
                Text("Fixed").tag(SizeKind.fixed)
                Text("Scaled").tag(SizeKind.scaled)
            }
            .onChange(of: kind) { _, _ in commit() }
            switch kind {
            case .drawable:
                EmptyView()

            case .fixed:
                HStack {
                    TextField("Width", value: $width, formatter: NumberFormatter())
                    TextField("Height", value: $height, formatter: NumberFormatter())
                }
                .onChange(of: width) { _, _ in commit() }
                .onChange(of: height) { _, _ in commit() }

            case .scaled:
                TextField("Scale", value: $scale, formatter: NumberFormatter())
                    .onChange(of: scale) { _, _ in commit() }
            }
        }
        .onAppear { hydrate() }
        .onChange(of: size) { _, _ in hydrate() }
    }

    private func hydrate() {
        switch size {
        case .drawable: kind = .drawable

        case .fixed(let w, let h):
            kind = .fixed; width = w; height = h

        case .scaledDrawable(let s):
            kind = .scaled; scale = s
        }
    }

    private func commit() {
        switch kind {
        case .drawable: size = .drawable
        case .fixed: size = .fixed(width: width, height: height)
        case .scaled: size = .scaledDrawable(scale)
        }
    }
}

private struct TextureInitField: View {
    @Binding var `init`: TextureInit

    @State private var kind: InitKind = .zero
    @State private var color: Color = .black
    @State private var filename: String = ""
    @State private var seed: UInt64 = 0

    private enum InitKind: String, CaseIterable {
        case zero
        case fill
        case image
        case noise
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Init", selection: $kind) {
                Text("Zero").tag(InitKind.zero)
                Text("Fill").tag(InitKind.fill)
                Text("Image").tag(InitKind.image)
                Text("Noise").tag(InitKind.noise)
            }
            .onChange(of: kind) { _, _ in commit() }
            switch kind {
            case .zero:
                EmptyView()

            case .fill:
                ColorPicker("Color", selection: $color, supportsOpacity: true)
                    .onChange(of: color) { _, _ in commit() }

            case .image:
                TextField("File", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: filename) { _, _ in commit() }

            case .noise:
                TextField("Seed", value: $seed, formatter: NumberFormatter())
                    .onChange(of: seed) { _, _ in commit() }
            }
        }
        .onAppear { hydrate() }
        .onChange(of: `init`) { _, _ in hydrate() }
    }

    private func hydrate() {
        switch `init` {
        case .zero: kind = .zero

        case .fill(let rgba):
            kind = .fill
            color = Color(red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z), opacity: Double(rgba.w))

        case .image(let file):
            kind = .image; filename = file

        case .noise(let s):
            kind = .noise; seed = s
        }
    }

    private func commit() {
        switch kind {
        case .zero:
            `init` = .zero

        case .fill:
            let resolved = color.resolve(in: .init())
            `init` = .fill(.init(resolved.red, resolved.green, resolved.blue, resolved.opacity))

        case .image:
            `init` = .image(file: filename)

        case .noise:
            `init` = .noise(seed: seed)
        }
    }
}

// MARK: - Passes

private struct PassesEditor: View {
    @Binding var passes: [Pass]
    let textures: [PhosphorSupport.Texture]

    var body: some View {
        ForEach($passes, id: \.id) { $pass in
            PassRow(pass: $pass, textures: textures)
        }
        Button {
            passes.append(uniqueNewPass(existing: passes))
        } label: {
            Label("Add Pass", systemImage: "plus")
        }
    }

    private func uniqueNewPass(existing: [Pass]) -> Pass {
        let used = Set(existing.map(\.id))
        var name = "pass"
        var counter = 2
        while used.contains(ResourceID(name)) {
            name = "pass\(counter)"
            counter += 1
        }
        return Pass(id: ResourceID(name))
    }
}

private struct PassRow: View {
    @Binding var pass: Pass
    let textures: [PhosphorSupport.Texture]

    var body: some View {
        DisclosureGroup(pass.id.raw) {
            ResourceIDField(label: "ID", id: $pass.id)
            Toggle("Enabled", isOn: $pass.enabled)

            Text("Texture Bindings").font(.caption).foregroundStyle(.secondary)
            ForEach($pass.textures, id: \.self) { $binding in
                BindingRow(binding: $binding, textures: textures)
            }
            Button {
                if let firstTexture = textures.first {
                    pass.textures.append(Pass.TextureBinding(id: firstTexture.id, access: .read))
                }
            } label: {
                Label("Add Binding", systemImage: "plus")
            }
            .disabled(textures.isEmpty)
        }
    }
}

private struct BindingRow: View {
    @Binding var binding: Pass.TextureBinding
    let textures: [PhosphorSupport.Texture]

    var body: some View {
        HStack {
            Picker("Texture", selection: $binding.id) {
                ForEach(textures, id: \.id) { texture in
                    Text(texture.id.raw).tag(texture.id)
                }
            }
            Picker("Access", selection: $binding.access) {
                Text("Read").tag(TextureAccess.read)
                Text("Sample").tag(TextureAccess.sample)
                Text("Write").tag(TextureAccess.write)
                Text("R/W").tag(TextureAccess.readWrite)
            }
            .frame(width: 100)
        }
    }
}

// MARK: - Uniforms

private struct UniformsEditor: View {
    @Binding var uniforms: [UniformDecl]

    var body: some View {
        ForEach($uniforms, id: \.name) { $uniform in
            UniformRow(uniform: $uniform)
        }
        Button {
            uniforms.append(UniformDecl(name: "newUniform", kind: .float, defaultValue: .float(0)))
        } label: {
            Label("Add Uniform", systemImage: "plus")
        }
    }
}

private struct UniformRow: View {
    @Binding var uniform: UniformDecl

    var body: some View {
        DisclosureGroup(uniform.name) {
            TextField("Name", text: $uniform.name)
                .textFieldStyle(.roundedBorder)
            Picker("Kind", selection: $uniform.kind) {
                ForEach(UniformKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
        }
    }
}

// MARK: - Shared

private struct ResourceIDField: View {
    let label: String
    @Binding var id: ResourceID

    @State private var raw: String = ""

    var body: some View {
        TextField(label, text: $raw)
            .textFieldStyle(.roundedBorder)
            .onAppear { raw = id.raw }
            .onChange(of: raw) { _, newValue in id = ResourceID(newValue) }
    }
}

// The `call(_:)` signature is fixed by CollaborationKit's `Tool` protocol
// (async; takes a typed `Input`); some tools don't await or use the input.
// swiftlint:disable async_without_await unused_parameter

import CollaborationKit
import Foundation
import Metal
import PhosphorCompile
import PhosphorModel

// The conversational shader tools, in two distinct surfaces:
//
// 1. Whole-file `read` / `write` / `edit` over the entire `.metal` source —
//    front-matter comment included — exactly as a human edits the file. This
//    is the default surface for most work.
// 2. `readConfiguration` / `writeConfiguration` — specialist tools that view
//    JUST the front-matter as a structured object. Preferred when changing
//    config, but the model CAN also touch config via the whole-file tools.
//
// Plus `compileShader` to check the result. The model converges by editing and
// compiling, not by re-emitting the whole file.

// MARK: - read (whole file)

/// Returns the entire current `.metal` source — front-matter comment and kernel
/// body — so the model can see exactly what it's editing. Call this before
/// editing if the current contents are unknown.
public struct ReadMetalTool: Tool {
    public struct Input: Decodable, Sendable {
        public init() {}
    }

    private let document: TextDocument

    public init(document: TextDocument) {
        self.document = document
    }

    public var name: String { "read" }
    public var description: String {
        "Read the entire current .metal source (front-matter comment and kernel body). Call this before editing if you don't know the current contents."
    }
    public var inputSchema: JSONValue {
        .object(["type": "object", "properties": .object([:])])
    }

    public func call(_ input: Input) async throws -> String {
        try readSource(document)
    }
}

// MARK: - write (whole file)

/// Overwrites the entire `.metal` source with new content. Use for creating
/// content from scratch or a wholesale rewrite; prefer `edit` for surgical
/// changes.
public struct WriteMetalTool: Tool {
    public struct Input: Decodable, Sendable {
        public let content: String
    }

    private let document: TextDocument

    public init(document: TextDocument) {
        self.document = document
    }

    public var name: String { "write" }
    public var description: String {
        "Overwrite the entire .metal source with new content. Provide the complete file, including the /* phosphor:environment ... */ front-matter and the kernel body. Prefer `edit` for small changes."
    }
    public var inputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "content": .object([
                    "type": "string",
                    "description": "The complete new .metal source."
                ])
            ]),
            "required": .array(["content"])
        ])
    }

    public func call(_ input: Input) async throws -> String {
        try writeSource(document, input.content)
        return "Wrote \(input.content.count) characters."
    }
}

// MARK: - edit (whole file)

/// Replaces an exact, unique span of text anywhere in the `.metal` source
/// (front-matter or body). A near-verbatim port of CollaborationKit's
/// `EditTool` — the model's main surgical-edit surface, just like editing a
/// normal file.
public struct EditMetalTool: Tool {
    public struct Input: Decodable, Sendable {
        public let oldText: String
        public let newText: String
    }

    private let document: TextDocument

    public init(document: TextDocument) {
        self.document = document
    }

    public var name: String { "edit" }
    public var description: String {
        """
        Replace an exact, unique span of text anywhere in the .metal source \
        (front-matter comment or kernel body). `oldText` must match exactly \
        once; include enough surrounding context to make it unique. Use `read` \
        first if you don't know the current contents, or `write` to create \
        content in an empty file. To change the structured configuration you \
        may also use writeConfiguration.
        """
    }
    public var inputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "oldText": .object([
                    "type": "string",
                    "description": "The exact text to replace. Must be unique in the file."
                ]),
                "newText": .object([
                    "type": "string",
                    "description": "The replacement text."
                ])
            ]),
            "required": .array(["oldText", "newText"])
        ])
    }

    public func call(_ input: Input) async throws -> String {
        let source = try readSource(document)

        let occurrences = source.components(separatedBy: input.oldText).count - 1
        switch occurrences {
        case 0:
            throw ToolError("`oldText` was not found in the source. Call `read` to see the current contents.")

        case 1:
            let updated = source.replacingOccurrences(of: input.oldText, with: input.newText)
            try writeSource(document, updated)
            return "Edit applied."

        default:
            throw ToolError("`oldText` matched \(occurrences) times; it must be unique. Add surrounding context.")
        }
    }
}

// MARK: - readConfiguration

/// Returns the current front-matter ``PhosphorConfiguration`` as JSON, so the
/// model can inspect the structured environment (textures, passes, uniforms,
/// output) without parsing the `.metal` text itself.
public struct ReadConfigurationTool: Tool {
    public struct Input: Decodable, Sendable {
        public init() {}
    }

    private let document: TextDocument

    public init(document: TextDocument) {
        self.document = document
    }

    public var name: String { "readConfiguration" }
    public var description: String {
        "Read the shader's structured front-matter configuration (textures, passes, uniforms, output) as JSON."
    }
    public var inputSchema: JSONValue {
        .object(["type": "object", "properties": .object([:])])
    }

    public func call(_ input: Input) async throws -> String {
        let source = try readSource(document)
        let parsed = ParsedPhosphorSource(source: source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(parsed.configuration)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ToolError("Failed to encode configuration: \(error)")
        }
    }
}

// MARK: - writeConfiguration

/// Replaces the front-matter configuration with a new structured value, then
/// re-emits the `/* phosphor:environment ... */` block via
/// ``FrontMatterFormatter`` and splices it onto the current body. The input is
/// the runtime ``PhosphorConfiguration`` shape directly — the same shape
/// ``ReadConfigurationTool`` returns (one representation, read/write symmetric).
/// The configuration typically changes little between turns, so a
/// coarse-grained whole-config write is the right grain.
public struct WriteConfigurationTool: Tool {
    public struct Input: Decodable, Sendable {
        public let configuration: PhosphorConfiguration
    }

    private let document: TextDocument

    public init(document: TextDocument) {
        self.document = document
    }

    public var name: String { "writeConfiguration" }
    public var description: String {
        """
        Replace the shader's structured front-matter configuration. Provide the \
        complete new configuration (textures, passes, uniforms, output). The \
        front-matter block is regenerated; the kernel body is preserved.
        """
    }
    public var inputSchema: JSONValue { PhosphorConfigurationSchema.jsonSchema }

    public func call(_ input: Input) async throws -> String {
        let configuration = input.configuration
        let diagnostics = validate(configuration)
        if let fatal = diagnostics.first(where: \.isFatal) {
            throw ToolError("Configuration is invalid: \(fatal)")
        }

        let toml: String
        do {
            toml = try FrontMatterFormatter.encodeBody(configuration)
        } catch {
            throw ToolError("Failed to encode configuration: \(error)")
        }

        let source = try readSource(document)
        let parsed = ParsedPhosphorSource(source: source)
        let block = FrontMatterFormatter.wrapFrontMatter(body: toml)
        // Preserve any leading comments (e.g. prompt history) above the body.
        let leading = parsed.hasFrontMatter ? leadingComments(of: source) : ""
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSource = "\(leading)\(block)\n\n\(body)\n"
        try writeSource(document, newSource)

        let warnings = diagnostics.filter { !$0.isFatal }
        if warnings.isEmpty {
            return "Configuration written."
        }
        return "Configuration written with warnings:\n" + warnings.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Captures whitespace + comment lines that appear *above* the front-matter
    /// block, so re-emitting the block keeps any `/* prompt: ... */` history.
    private func leadingComments(of source: String) -> String {
        guard let markerRange = source.range(of: "/* phosphor:environment") else { return "" }
        return String(source[..<markerRange.lowerBound])
    }
}

// MARK: - compileShader

/// Compiles the live `.metal` source and reports the result back to the model:
/// the first compile error plus any front-matter/validation diagnostics on
/// failure, or "compiles cleanly" on success. This is the self-correction
/// primitive — the model edits, compiles, reads the error, edits again.
public struct CompileShaderTool: Tool {
    public struct Input: Decodable, Sendable {
        public init() {}
    }

    /// Compiles a parsed source and returns a human-readable diagnostic
    /// summary (empty when it compiles cleanly). Injected so the host can wire
    /// a real `MTLDevice`, and tests can supply a fake.
    public typealias CompileCheck = @Sendable (ParsedPhosphorSource) -> String?

    private let document: TextDocument
    private let compileCheck: CompileCheck

    public init(document: TextDocument, compileCheck: @escaping CompileCheck) {
        self.document = document
        self.compileCheck = compileCheck
    }

    /// Convenience initializer that compiles against a live `MTLDevice` via
    /// ``ShaderCompiler``, reporting front-matter, validation, and Metal
    /// compiler diagnostics.
    public init(document: TextDocument, device: MTLDevice) {
        self.init(document: document) { parsed in
            let compiled = ShaderCompiler.compile(parsed: parsed, device: device)
            let messages = compiled.diagnostics.map { "\($0)" }
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
    }

    public var name: String { "compileShader" }
    public var description: String {
        "Compile the current shader and report any Metal compiler or configuration errors. Call this after editing to check your work."
    }
    public var inputSchema: JSONValue {
        .object(["type": "object", "properties": .object([:])])
    }

    public func call(_ input: Input) async throws -> String {
        let source = try readSource(document)
        let parsed = ParsedPhosphorSource(source: source)
        if let diagnostics = compileCheck(parsed) {
            return "Compile failed:\n\(diagnostics)"
        }
        return "Compiles cleanly."
    }
}

// MARK: - Tool set

extension Array where Element == AnyTool {
    /// The conversational shader tool set over one document: whole-file
    /// read/write/edit, the specialist read/write configuration tools, and
    /// compile to check.
    public static func shaderTools(for document: TextDocument, device: MTLDevice) -> [AnyTool] {
        fileTools(for: document) + [
            ReadConfigurationTool(document: document).eraseToAnyTool(),
            WriteConfigurationTool(document: document).eraseToAnyTool(),
            CompileShaderTool(document: document, device: device).eraseToAnyTool()
        ]
    }

    /// Tool set with an injected compile check, for tests without a device.
    public static func shaderTools(for document: TextDocument, compileCheck: @escaping CompileShaderTool.CompileCheck) -> [AnyTool] {
        fileTools(for: document) + [
            ReadConfigurationTool(document: document).eraseToAnyTool(),
            WriteConfigurationTool(document: document).eraseToAnyTool(),
            CompileShaderTool(document: document, compileCheck: compileCheck).eraseToAnyTool()
        ]
    }

    /// The whole-file read/write/edit tools — the default editing surface.
    private static func fileTools(for document: TextDocument) -> [AnyTool] {
        [
            ReadMetalTool(document: document).eraseToAnyTool(),
            WriteMetalTool(document: document).eraseToAnyTool(),
            EditMetalTool(document: document).eraseToAnyTool()
        ]
    }
}

// MARK: - Shared helpers

private func readSource(_ document: TextDocument) throws -> String {
    do {
        return try document.read()
    } catch {
        throw ToolError("Failed to read document: \(error.localizedDescription)")
    }
}

private func writeSource(_ document: TextDocument, _ text: String) throws {
    do {
        try document.write(text)
    } catch {
        throw ToolError("Failed to write document: \(error.localizedDescription)")
    }
}

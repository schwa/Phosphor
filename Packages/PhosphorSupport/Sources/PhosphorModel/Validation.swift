import Foundation

/// Validates a ``PhosphorConfiguration`` and returns any structural diagnostics.
///
/// Returns an empty array if the configuration is well-formed. The runtime
/// refuses to materialize an configuration that has any fatal diagnostics
/// (which all validation diagnostics are; see ``PhosphorDiagnostic/isFatal``).
public func validate(_ config: PhosphorConfiguration) -> [PhosphorDiagnostic] {
    var diagnostics: [PhosphorDiagnostic] = []

    // Duplicate textures + image/ping-pong conflict.
    var seenTextureIDs: Set<ResourceID> = []
    for texture in config.textures {
        if !seenTextureIDs.insert(texture.id).inserted {
            diagnostics.append(.duplicateResource(texture.id))
        }
        if case .image = texture.initialContents, texture.swap != .none {
            diagnostics.append(.imageTextureCannotPingPong(texture.id))
        }
    }
    let textureIDs = Set(config.textures.map(\.id))

    // Duplicate passes.
    var seenPassIDs: Set<ResourceID> = []
    for pass in config.passes {
        if !seenPassIDs.insert(pass.id).inserted {
            diagnostics.append(.duplicatePass(pass.id))
        }
    }

    // Env-level output must reference a declared texture.
    if !textureIDs.contains(config.output) {
        diagnostics.append(.missingOutput(config.output))
    }

    for pass in config.passes {
        var seenBindingNames: Set<String> = []
        var writeBindings: [Pass.TextureBinding] = []
        var readBindings: [Pass.TextureBinding] = []

        for binding in pass.textures {
            if !seenBindingNames.insert(binding.effectiveName).inserted {
                diagnostics.append(.duplicateBinding(name: binding.effectiveName, in: pass.id))
            }
            if !textureIDs.contains(binding.id) {
                diagnostics.append(.unknownResource(binding.id, in: "pass \"\(pass.id)\" binding"))
            }
            switch binding.access {
            case .write, .readWrite:
                writeBindings.append(binding)

            case .read, .sample:
                readBindings.append(binding)
            }
        }

        // Every pass must declare at least one write-capable binding.
        // Otherwise it has nowhere to put its output.
        if writeBindings.isEmpty {
            diagnostics.append(.passHasNoOutput(pass: pass.id))
        }

        // Read/write hazard: writing AND reading the same texture in the
        // same pass without ping-pong is undefined.
        for write in writeBindings {
            for read in readBindings where read.id == write.id {
                let texture = config.texture(write.id)
                if texture?.swap == SwapTiming.none {
                    diagnostics.append(.readWriteHazard(pass: pass.id, resource: write.id))
                }
            }
        }
    }

    return diagnostics
}

import Foundation

/// Validates a ``PhosphorEnvironment`` and returns any structural diagnostics.
///
/// Returns an empty array if the environment is well-formed. The runtime
/// refuses to materialize an environment that has any fatal diagnostics
/// (which all validation diagnostics are; see ``PhosphorDiagnostic/isFatal``).
public func validate(_ env: PhosphorEnvironment) -> [PhosphorDiagnostic] {
    var diagnostics: [PhosphorDiagnostic] = []

    // Duplicate textures.
    var seenTextureIDs: Set<ResourceID> = []
    for texture in env.textures {
        if !seenTextureIDs.insert(texture.id).inserted {
            diagnostics.append(.duplicateResource(texture.id))
        }
    }
    let textureIDs = Set(env.textures.map(\.id))

    // Duplicate passes.
    var seenPassIDs: Set<ResourceID> = []
    for pass in env.passes {
        if !seenPassIDs.insert(pass.id).inserted {
            diagnostics.append(.duplicatePass(pass.id))
        }
    }

    // Env-level output must reference a declared texture.
    if !textureIDs.contains(env.output) {
        diagnostics.append(.missingOutput(env.output))
    }

    for pass in env.passes {
        var seenBindingIDs: Set<ResourceID> = []
        var writeBindings: [Pass.TextureBinding] = []
        var readBindings: [Pass.TextureBinding] = []

        for binding in pass.textures {
            if !seenBindingIDs.insert(binding.id).inserted {
                diagnostics.append(.duplicateBinding(name: binding.id.raw, in: pass.id))
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
                let texture = env.texture(write.id)
                if texture?.swap == SwapTiming.none {
                    diagnostics.append(.readWriteHazard(pass: pass.id, resource: write.id))
                }
            }
        }
    }

    return diagnostics
}

import Foundation

/// Validates a ``PhosphorEnvironment`` and returns any structural diagnostics.
///
/// Returns an empty array if the environment is well-formed. The runtime
/// refuses to materialize an environment that has any fatal diagnostics
/// (which all validation diagnostics are; see ``PhosphorDiagnostic/isFatal``).
public func validate(_ env: PhosphorEnvironment) -> [PhosphorDiagnostic] {
    var diagnostics: [PhosphorDiagnostic] = []

    // Duplicate resources.
    var seenResourceIDs: Set<ResourceID> = []
    for resource in env.resources {
        if !seenResourceIDs.insert(resource.id).inserted {
            diagnostics.append(.duplicateResource(resource.id))
        }
    }
    let resourceIDs = Set(env.resources.map(\.id))

    // Duplicate passes.
    var seenPassIDs: Set<ResourceID> = []
    for pass in env.passes {
        if !seenPassIDs.insert(pass.id).inserted {
            diagnostics.append(.duplicatePass(pass.id))
        }
    }

    // Output resource exists.
    if !resourceIDs.contains(env.output) {
        diagnostics.append(.missingOutput(env.output))
    }

    // Inferred channel count, for range checks. Errors don't update the inferred
    // count; only valid `iChannelN` names contribute.
    let inferredCount = channelCount(for: env)

    for pass in env.passes {
        if !resourceIDs.contains(pass.output) {
            diagnostics.append(.unknownResource(pass.output, in: "pass \"\(pass.id)\" output"))
        }

        var seenBindingNames: Set<String> = []
        for binding in pass.inputs {
            if !seenBindingNames.insert(binding.name).inserted {
                diagnostics.append(.duplicateBinding(name: binding.name, in: pass.id))
            }
            if let index = channelIndex(from: binding.name) {
                if index >= inferredCount {
                    // Should be impossible: if this binding referenced an index
                    // beyond inferredCount, inferredCount would be at least
                    // index+1. Keep the case for defense-in-depth.
                    diagnostics.append(.channelOutOfRange(name: binding.name, inferred: inferredCount))
                }
            } else {
                diagnostics.append(.unknownChannelName(binding.name, in: pass.id))
            }
            if !resourceIDs.contains(binding.resource) {
                diagnostics.append(.unknownResource(binding.resource, in: "pass \"\(pass.id)\" input \"\(binding.name)\""))
            }
        }

        // A pass can't write to a read-only `.image` resource.
        if case .image = env.resource(pass.output) {
            diagnostics.append(.readWriteHazard(pass: pass.id, resource: pass.output))
        }

        // Read/write hazard: writing to a non-ping-pong resource that is also
        // sampled as an input. (Sampling the same ping-pong resource is fine —
        // that's the standard feedback pattern.)
        for binding in pass.inputs where binding.resource == pass.output {
            if case .texture2D(_, let spec) = env.resource(pass.output) ?? .texture2D(id: pass.output, spec: .init()),
               !spec.pingPong {
                diagnostics.append(.readWriteHazard(pass: pass.id, resource: pass.output))
            }
        }
    }

    return diagnostics
}

/// The inferred channel-rack size for an environment.
///
/// Equal to `max(N referenced in any pass binding's "iChannelN") + 1`, or `0`
/// if no pass references any channel.
public func channelCount(for env: PhosphorEnvironment) -> Int {
    var maxIndex: Int = -1
    for pass in env.passes {
        for binding in pass.inputs {
            if let index = channelIndex(from: binding.name) {
                maxIndex = max(maxIndex, index)
            }
        }
    }
    return maxIndex + 1
}

/// Parses `"iChannelN"` and returns `N`, or nil if the string isn't of that form.
public func channelIndex(from name: String) -> Int? {
    let prefix = "iChannel"
    guard name.hasPrefix(prefix) else { return nil }
    let suffix = name.dropFirst(prefix.count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber) else {
        return nil
    }
    return Int(suffix)
}

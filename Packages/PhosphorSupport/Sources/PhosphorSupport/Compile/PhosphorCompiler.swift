import Foundation
import Metal

/// Compiles assembled Metal source into an `MTLLibrary`, and extracts
/// per-pass `MTLComputePipelineState`s by kernel name.
public struct PhosphorCompiler {
    public let device: MTLDevice

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Assembles + compiles a `MTLLibrary` for the environment.
    ///
    /// `userSource` is the full user-supplied Metal text (front-matter and
    /// `#include "Phosphor.h"` lines are tolerated and stripped). The
    /// returned library contains every kernel declared in the user source.
    public func compileLibrary(environment: PhosphorEnvironment, userSource: String) throws -> MTLLibrary {
        let assembled = SourceAssembler.assemble(environment: environment, userSource: userSource)
        return try device.makeLibrary(source: assembled, options: nil)
    }

    /// Builds a compute pipeline state for one pass, looking up
    /// `function(named: passID)` in `library`.
    public func makePipelineState(library: MTLLibrary, for passID: ResourceID) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: passID.raw) else {
            throw PhosphorCompileFailure.functionNotFound(passID)
        }
        return try device.makeComputePipelineState(function: function)
    }
}

/// Errors thrown by ``PhosphorCompiler``. Per-pass compile errors raised by
/// Metal itself surface as the usual `NSError` from `makeLibrary(source:)`;
/// only Phosphor-specific failures are modeled here.
public enum PhosphorCompileFailure: Error, Hashable, Sendable {
    case functionNotFound(ResourceID)
}

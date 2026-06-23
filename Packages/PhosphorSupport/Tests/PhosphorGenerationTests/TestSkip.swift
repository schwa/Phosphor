import Foundation

/// Thrown to skip a test when no Metal device is available.
enum TestSkip: Error {
    case noDevice
}

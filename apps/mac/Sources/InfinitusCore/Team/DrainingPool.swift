import Foundation

/// Runs `body` inside its own autorelease pool on Darwin (a no-op
/// elsewhere). The team queue does a whole publish or header scan as ONE
/// block, and Foundation hands back autoreleased objects on every step —
/// regex results in the redactor, JSONSerialization output, NSTask pipe
/// buffers — which stayed alive until that block returned: 10–14 GB RSS
/// on the first real publish (2026-09-06). Every per-item loop drains.
@inline(__always)
func drainingPool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

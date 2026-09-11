import SwiftUI
import InfinitusCore

/// Every engine failure a settings pane shows the user, as a sentence
/// with a next step. The raw `Error` never reaches the window: a
/// `CLIError`'s text carries the engine's argv ("swapd add
/// exited 1"), a `DecodingError` its coding path, and an `NSError` its
/// debug description — none of the three tells anyone what to do next
/// (the critique's [P2], four sites). Its own file because every pane in
/// the settings group and the fleet state call it (one module).
enum EngineFailure {
    static func sentence(_ error: Error) -> String {
        if let engine = error as? EngineError {
            switch engine {
            case .unsupported:
                return "This engine doesn't support that action. Nothing changed."
            case .unreachable:
                return "Infinitus can't reach the engine. Check it is running and its address is right, then try again."
            case .unauthorized:
                return "The engine refused the key. Check the key and save it again."
            case .remote(let status, _):
                return "The engine answered with an error (\(status)). Check the engine, then try again."
            }
        }
        if error is CLIError {
            return "The engine refused that change. Check it is running, then try again."
        }
        if error is DecodingError {
            return "The engine answered in a form this version doesn't understand. Update the engine, then try again."
        }
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSPOSIXErrorDomain, Int(ENOENT)):
            return "The engine isn't where Infinitus expects it. Reinstall it, then try again."
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError), (NSPOSIXErrorDomain, Int(EACCES)):
            return "Infinitus isn't allowed to run the engine. Check its permissions, then try again."
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            return "No network connection \u{2014} reconnect, then try again."
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return "The engine didn't answer in time. Check it is running, then try again."
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost):
            return "Nothing answered at that address. Check the address and that the engine is running."
        default:
            return "Couldn't save \u{2014} try again."
        }
    }
}

extension JSONValue {
    /// The text a user would type to reproduce this value.
    var editableText: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }
}

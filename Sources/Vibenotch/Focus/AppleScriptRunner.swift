import AppKit
import Foundation

enum AppleScriptRunner {
    private static let eventNotHandled = -1708
    private static let eventNotPermitted = -1743

    static func run(_ source: String) throws -> String? {
        if Thread.isMainThread {
            return try execute(source)
        }

        return try DispatchQueue.main.sync {
            try execute(source)
        }
    }

    private static func execute(_ source: String) throws -> String? {
        guard let script = NSAppleScript(source: source) else {
            throw FocusError.scriptFailed("Could not create AppleScript.")
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String
                ?? "AppleScript failed."

            if code == eventNotPermitted || code == eventNotHandled {
                throw FocusError.permissionDenied(message)
            }

            throw FocusError.scriptFailed(message)
        }

        return output.stringValue
    }
}

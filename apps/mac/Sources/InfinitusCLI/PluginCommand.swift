import Foundation

/// `infinitusctl plugin install|uninstall|status`: the Claude Code plugin
/// (#79) lives in this repo as a marketplace entry; `claude` installs it.
enum PluginCommand {
    static let marketplace = "deathemperor/infinitus"
    static let plugin = "infinitus@infinitus"

    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "install":
            // Adding twice fails harmlessly; the install is what matters.
            _ = claude(["plugin", "marketplace", "add", marketplace])
            return claude(["plugin", "install", plugin])
        case "uninstall":
            return claude(["plugin", "uninstall", plugin])
        case "status":
            return claude(["plugin", "list"])
        default:
            FileHandle.standardError.write(Data("""
            usage: infinitusctl plugin install|uninstall|status
              install    adds the \(marketplace) marketplace to Claude Code and installs \(plugin)
              uninstall  removes the plugin
              status     lists Claude Code's installed plugins

            """.utf8))
            return 2
        }
    }

    private static func claude(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude"] + arguments
        do { try process.run() } catch {
            FileHandle.standardError.write(Data("claude is not on PATH: install Claude Code first\n".utf8))
            return 3
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
